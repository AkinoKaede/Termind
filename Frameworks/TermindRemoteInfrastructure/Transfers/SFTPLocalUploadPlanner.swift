import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SFTPLocalUploadBatch: Sendable {
    fileprivate struct Job: Sendable {
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
        client: any SFTPClientProtocol
    ) async throws -> SFTPLocalUploadBatch {
        var jobs: [SFTPLocalUploadBatch.Job] = []
        var directories: [String] = []

        for root in urls where root.isFileURL {
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
        client: any SFTPClientProtocol,
        coordinator: SFTPTransferCoordinator,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) async throws -> SFTPLocalUploadEnqueueResult {
        let remoteResolution = try await SFTPRemoteConflictResolver.resolveDirectories(
            batch.remoteDirectories,
            conflicts: batch.remoteDirectoryConflicts,
            policy: policy,
            client: client
        )
        var transferCount = 0
        for var job in batch.jobs {
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
                else { continue }
                job.remotePath = resolved.path
                job.hasConflict = resolved.overwrite
            }
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
                completion: completion
            )
            transferCount += 1
        }
        return SFTPLocalUploadEnqueueResult(
            transferCount: transferCount,
            changedRemoteDirectories: remoteResolution.changed
        )
    }

}
