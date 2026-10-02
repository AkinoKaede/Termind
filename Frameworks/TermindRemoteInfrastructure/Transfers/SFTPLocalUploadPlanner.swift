import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SFTPLocalUploadBatch: Sendable {
    fileprivate struct Job: Sendable {
        var rootIndex: Int
        var localURL: URL
        var remotePath: String
        var byteCount: Int64
        var scopedRoot: URL
        var hasConflict: Bool
        var conflictingTargetIsDirectory: Bool
    }

    public let id: UUID
    public let rootCount: Int
    public let conflictCount: Int
    fileprivate var roots: [String]
    fileprivate var jobs: [Job]
    fileprivate var remoteDirectories: [String]
    fileprivate var remoteDirectoryConflicts: Set<String>

    public var transferCount: Int { jobs.count }
    public var isEmpty: Bool { jobs.isEmpty && remoteDirectories.isEmpty }
}

public nonisolated struct SFTPLocalUploadEnqueueResult: Equatable, Sendable {
    public let transferCount: Int
    public let changedRemoteDirectories: Bool
}

public enum SFTPLocalUploadPlanner {
    @MainActor
    public static func prepare(
        _ urls: [URL],
        destination: String,
        client: any SFTPChannelProtocol
    ) async throws -> SFTPLocalUploadBatch {
        var jobs: [SFTPLocalUploadBatch.Job] = []
        var directories: [String] = []

        let urls = urls.filter(\.isFileURL)
        for (rootIndex, root) in urls.enumerated() {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let rootDestination = RemotePath.join(destination, root.lastPathComponent)
            if values.isDirectory == true {
                let resolvedRootPath = root.resolvingSymlinksInPath().path
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsPackageDescendants]
                )
                directories.append(rootDestination)
                while let item = enumerator?.nextObject() as? URL {
                    let resolvedItemPath = item.resolvingSymlinksInPath().path
                    guard resolvedItemPath.hasPrefix(resolvedRootPath + "/") else { continue }
                    let relative = String(resolvedItemPath.dropFirst(resolvedRootPath.count + 1))
                    let remotePath = RemotePath.join(rootDestination, relative)
                    let itemValues = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if itemValues.isDirectory == true {
                        directories.append(remotePath)
                    } else {
                        jobs.append(
                            SFTPLocalUploadBatch.Job(
                                rootIndex: rootIndex,
                                localURL: item,
                                remotePath: remotePath,
                                byteCount: Int64(itemValues.fileSize ?? 0),
                                scopedRoot: root,
                                hasConflict: false,
                                conflictingTargetIsDirectory: false
                            ))
                    }
                }
            } else {
                jobs.append(
                    SFTPLocalUploadBatch.Job(
                        rootIndex: rootIndex,
                        localURL: root,
                        remotePath: rootDestination,
                        byteCount: Int64(values.fileSize ?? 0),
                        scopedRoot: root,
                        hasConflict: false,
                        conflictingTargetIsDirectory: false
                    ))
            }
        }

        let preflight = try await SFTPRemoteConflictResolver.preflight(
            directories: directories, targets: jobs.map(\.remotePath),
            includeConflictingRoot: false, client: client)
        for (index, kind) in zip(jobs.indices, preflight.targetKinds) {
            guard let kind else { continue }
            jobs[index].hasConflict = true
            jobs[index].conflictingTargetIsDirectory = kind
        }
        return SFTPLocalUploadBatch(
            id: UUID(),
            rootCount: urls.filter(\.isFileURL).count,
            conflictCount: preflight.conflictCount,
            roots: urls.map { RemotePath.join(destination, $0.lastPathComponent) },
            jobs: jobs,
            remoteDirectories: preflight.directories,
            remoteDirectoryConflicts: preflight.directoryConflicts
        )
    }

    @MainActor
    public static func enqueue(
        _ batch: SFTPLocalUploadBatch,
        policy: TransferConflictPolicy,
        hostID: Host.ID,
        connection: SFTPTransferConnection,
        homeDirectory: String? = nil,
        client: any SFTPChannelProtocol,
        coordinator: SFTPTransferCoordinator,
        uploadedPaths: (([String]) -> Void)? = nil,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) async throws -> SFTPLocalUploadEnqueueResult {
        let receipt = SFTPUploadReceipt(paths: batch.roots, completion: uploadedPaths)
        defer { receipt.finishAdmission() }
        do {
            let remoteResolution = try await SFTPRemoteConflictResolver.resolveDirectories(
                batch.remoteDirectories,
                conflicts: batch.remoteDirectoryConflicts,
                policy: policy,
                client: client
            )
            for (index, root) in batch.roots.enumerated() {
                receipt.resolve(index, to: remoteResolution.destination(for: root))
                if remoteResolution.skipped.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) {
                    receipt.reject(index)
                }
            }
            var transferCount = 0
            for var job in batch.jobs {
                try Task.checkCancellation()
                guard let destination = remoteResolution.destination(for: job.remotePath) else { continue }
                if destination != job.remotePath { job.hasConflict = false }
                job.remotePath = destination
                if job.hasConflict {
                    guard
                        let resolved = try await SFTPRemoteConflictResolver.resolveConflict(
                            path: job.remotePath,
                            conflictingTargetIsDirectory: job.conflictingTargetIsDirectory,
                            policy: policy,
                            client: client
                        )
                    else {
                        receipt.reject(job.rootIndex)
                        continue
                    }
                    job.remotePath = resolved.path
                    job.hasConflict = resolved.overwrite
                }
                try Task.checkCancellation()
                let rootIndex = job.rootIndex
                if job.scopedRoot == job.localURL { receipt.resolve(rootIndex, to: job.remotePath) }
                receipt.admit(rootIndex)
                coordinator.enqueue(
                    direction: .upload,
                    batchID: batch.id,
                    localURL: job.localURL,
                    remotePath: job.remotePath,
                    byteCount: job.byteCount,
                    hostID: hostID,
                    connection: connection,
                    scopedRoot: job.scopedRoot,
                    overwrite: job.hasConflict && policy == .replace,
                    homeDirectory: homeDirectory,
                    completion: { state in
                        receipt.completed(rootIndex, state: state)
                        completion?(state)
                    }
                )
                transferCount += 1
            }
            return SFTPLocalUploadEnqueueResult(
                transferCount: transferCount,
                changedRemoteDirectories: remoteResolution.changed
            )
        } catch {
            receipt.cancel()
            throw error
        }
    }

}

/// Collects final root paths after all admitted transfers finish. Admission may
/// suspend while an earlier transfer finishes, so completion waits for both.
@MainActor
final class SFTPUploadReceipt {
    private var paths: [String?]
    private var rejected: Set<Int> = []
    private var pending = 0
    private var admissionFinished = false
    private var completion: (([String]) -> Void)?

    init(paths: [String], completion: (([String]) -> Void)?) {
        self.paths = paths.map { $0 }
        self.completion = completion
    }

    func resolve(_ index: Int, to path: String?) { paths[index] = path }
    func reject(_ index: Int) { rejected.insert(index) }
    func admit(_ index: Int) { pending += 1 }
    func completed(_ index: Int, state: SFTPTransfer.State) {
        if state != .completed { reject(index) }
        pending -= 1
        deliverIfFinished()
    }
    func finishAdmission() {
        admissionFinished = true
        deliverIfFinished()
    }
    func cancel() { completion = nil }
    private func deliverIfFinished() {
        guard admissionFinished, pending == 0, let completion else { return }
        self.completion = nil
        let successful = paths.enumerated().compactMap { rejected.contains($0.offset) ? nil : $0.element }
        if !successful.isEmpty { completion(successful) }
    }
}
