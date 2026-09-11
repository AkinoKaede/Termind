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
    private struct RemoteConflictPreflight {
        var directories: [String]
        var directoryConflicts: Set<String>
        var targetKinds: [Bool?]
        var conflictCount: Int
    }

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

        let preflight = try await remoteConflictPreflight(
            directories: directories,
            targets: jobs.map(\.remotePath),
            client: client
        )
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
        let remoteResolution = try await resolveRemoteDirectories(
            batch.remoteDirectories,
            conflicts: batch.remoteDirectoryConflicts,
            policy: policy,
            client: client
        )
        var transferCount = 0
        for var job in batch.jobs {
            if remoteResolution.skipped.contains(where: {
                job.remotePath == $0 || job.remotePath.hasPrefix($0 + "/")
            }) {
                continue
            }
            for mapping in remoteResolution.mappings
            where job.remotePath == mapping.0 || job.remotePath.hasPrefix(mapping.0 + "/") {
                job.remotePath = mapping.1 + job.remotePath.dropFirst(mapping.0.count)
                job.hasConflict = false
            }
            if job.hasConflict {
                guard
                    let resolved = try await resolveRemoteConflict(
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

    @MainActor
    private static func remoteConflictPreflight(
        directories: [String],
        targets: [String],
        client: any SFTPClientProtocol
    ) async throws -> RemoteConflictPreflight {
        let directories = directories.sorted { $0.count < $1.count }
        var directoryConflicts: Set<String> = []
        var targetKinds: [Bool?] = []
        var conflictCount = 0

        for directory in directories {
            guard !directoryConflicts.contains(where: { directory.hasPrefix($0 + "/") }) else {
                continue
            }
            if let existing = try await client.attributes(at: directory), !existing.isDirectory {
                directoryConflicts.insert(directory)
                conflictCount += 1
            }
        }
        for target in targets {
            if directoryConflicts.contains(where: { target.hasPrefix($0 + "/") }) {
                targetKinds.append(nil)
                continue
            }
            let existing = try await client.attributes(at: target)
            targetKinds.append(existing?.isDirectory)
            if existing != nil { conflictCount += 1 }
        }
        return RemoteConflictPreflight(
            directories: directories,
            directoryConflicts: directoryConflicts,
            targetKinds: targetKinds,
            conflictCount: conflictCount
        )
    }

    private struct RemoteDirectoryResolution {
        var skipped: [String] = []
        var mappings: [(String, String)] = []
        var changed = false
    }

    @MainActor
    private static func resolveRemoteDirectories(
        _ directories: [String],
        conflicts: Set<String>,
        policy: TransferConflictPolicy,
        client: any SFTPClientProtocol
    ) async throws -> RemoteDirectoryResolution {
        var result = RemoteDirectoryResolution()
        for original in directories {
            if result.skipped.contains(where: {
                original == $0 || original.hasPrefix($0 + "/")
            }) {
                continue
            }
            var destination = original
            for mapping in result.mappings
            where destination == mapping.0 || destination.hasPrefix(mapping.0 + "/") {
                destination = mapping.1 + destination.dropFirst(mapping.0.count)
            }
            if conflicts.contains(original) {
                switch policy {
                case .skip:
                    result.skipped.append(original)
                    continue
                case .replace:
                    try await client.removeFile(at: original)
                    result.changed = true
                case .keepBoth:
                    destination = try await availableRemotePath(for: original, client: client)
                    result.mappings.append((original, destination))
                }
            }
            if try await client.attributes(at: destination) == nil {
                try await client.createDirectory(at: destination)
                result.changed = true
            }
        }
        return result
    }

    @MainActor
    private static func resolveRemoteConflict(
        path: String,
        conflictingTargetIsDirectory: Bool,
        policy: TransferConflictPolicy,
        client: any SFTPClientProtocol
    ) async throws -> (path: String, overwrite: Bool)? {
        switch policy {
        case .skip:
            return nil
        case .replace:
            if conflictingTargetIsDirectory,
                let existing = try await client.attributes(at: path)
            {
                try await deleteRecursively(existing, client: client)
            }
            return (path, true)
        case .keepBoth:
            return (try await availableRemotePath(for: path, client: client), false)
        }
    }

    @MainActor
    private static func availableRemotePath(
        for path: String,
        client: any SFTPClientProtocol
    ) async throws -> String {
        var index = 2
        var candidate = RemotePath.keepBothCandidate(for: path, index: index)
        while try await client.attributes(at: candidate) != nil {
            index += 1
            candidate = RemotePath.keepBothCandidate(for: path, index: index)
        }
        return candidate
    }

    @MainActor
    private static func deleteRecursively(
        _ file: RemoteFile,
        client: any SFTPClientProtocol
    ) async throws {
        if file.isDirectory {
            for child in try await client.listDirectory(at: file.path) {
                try await deleteRecursively(child, client: client)
            }
            try await client.removeDirectory(at: file.path)
        } else {
            try await client.removeFile(at: file.path)
        }
    }
}
