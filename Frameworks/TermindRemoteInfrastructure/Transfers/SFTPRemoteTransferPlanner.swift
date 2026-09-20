import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SFTPRemoteDownloadBatch: Sendable {
    public struct Job: Sendable {
        var remotePath: String
        var localURL: URL
        var byteCount: Int64
        var hasConflict: Bool
        var conflictingTargetIsDirectory: Bool
    }

    public var id = UUID()
    var jobs: [Job]
    var directories: [URL]
    var directoryConflicts: Set<URL>
    public var destination: URL
    public var conflictCount: Int
    public var transferCount: Int { jobs.count }
    public var directoryCount: Int { directories.count }
}

public nonisolated enum SFTPRemoteDownloadPlanner {
    public static func prepare(
        _ files: [RemoteFile], destination: URL,
        client: any SFTPChannelProtocol
    ) async throws -> SFTPRemoteDownloadBatch {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        var jobs: [SFTPRemoteDownloadBatch.Job] = []
        var directories: [URL] = []
        var directoryConflicts: Set<URL> = []
        var conflicts = 0

        func collect(_ remote: RemoteFile, local: URL) async throws {
            if remote.isDirectory {
                directories.append(local)
                for child in try await client.listDirectory(at: remote.path) {
                    try await collect(child, local: local.appending(path: child.name))
                }
                return
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
            if exists { conflicts += 1 }
            jobs.append(
                .init(
                    remotePath: remote.path, localURL: local, byteCount: remote.size,
                    hasConflict: exists,
                    conflictingTargetIsDirectory: exists && isDirectory.boolValue
                ))
        }

        for file in files {
            try await collect(file, local: destination.appending(path: file.name))
        }
        for directory in directories {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            {
                directoryConflicts.insert(directory)
                conflicts += 1
            }
        }
        return SFTPRemoteDownloadBatch(
            jobs: jobs, directories: directories,
            directoryConflicts: directoryConflicts,
            destination: destination, conflictCount: conflicts
        )
    }

    @MainActor public static func enqueue(
        _ batch: SFTPRemoteDownloadBatch,
        policy: TransferConflictPolicy,
        hostID: Host.ID,
        connection: SFTPTransferConnection,
        homeDirectory: String? = nil,
        coordinator: SFTPTransferCoordinator,
        completion: ((String, SFTPTransfer.State) -> Void)? = nil
    ) throws {
        let scoped = batch.destination.startAccessingSecurityScopedResource()
        defer { if scoped { batch.destination.stopAccessingSecurityScopedResource() } }
        var skippedPrefixes: [URL] = []
        var mappings: [(URL, URL)] = []
        for original in batch.directories {
            if skippedPrefixes.contains(where: { contains(original, in: $0) }) { continue }
            var directory = mapped(original, using: mappings)
            if batch.directoryConflicts.contains(original) {
                switch policy {
                case .skip:
                    skippedPrefixes.append(original)
                    continue
                case .replace:
                    try FileManager.default.removeItem(at: original)
                case .keepBoth:
                    let candidate = keepBothURL(original)
                    mappings.append((original, candidate))
                    directory = candidate
                }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        for var job in batch.jobs {
            if skippedPrefixes.contains(where: { contains(job.localURL, in: $0) }) { continue }
            job.localURL = mapped(job.localURL, using: mappings)
            if job.hasConflict {
                switch policy {
                case .skip: continue
                case .replace:
                    if job.conflictingTargetIsDirectory {
                        try FileManager.default.removeItem(at: job.localURL)
                    }
                case .keepBoth:
                    job.localURL = keepBothURL(job.localURL)
                }
            }
            try FileManager.default.createDirectory(
                at: job.localURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            coordinator.enqueue(
                direction: .download, batchID: batch.id,
                localURL: job.localURL, remotePath: job.remotePath,
                byteCount: job.byteCount, hostID: hostID,
                connection: connection, scopedRoot: batch.destination,
                overwrite: job.hasConflict && policy == .replace,
                homeDirectory: homeDirectory
            ) { state in completion?(job.remotePath, state) }
        }
    }

    private static func contains(_ url: URL, in prefix: URL) -> Bool {
        url.path == prefix.path || url.path.hasPrefix(prefix.path + "/")
    }

    private static func mapped(_ url: URL, using mappings: [(URL, URL)]) -> URL {
        for mapping in mappings where contains(url, in: mapping.0) {
            return URL(fileURLWithPath: mapping.1.path + url.path.dropFirst(mapping.0.path.count))
        }
        return url
    }

    private static func keepBothURL(_ url: URL) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        var index = 2
        while true {
            let name =
                ext.isEmpty
                ? "\(base.lastPathComponent).\(index)"
                : "\(base.lastPathComponent).\(index).\(ext)"
            let candidate = base.deletingLastPathComponent().appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

public nonisolated struct SFTPRemoteCopyBatch: Sendable {
    public struct Job: Sendable {
        var sourcePath: String
        var destinationPath: String
        var byteCount: Int64
        var hasConflict: Bool
        var conflictingTargetIsDirectory: Bool
    }

    public var id = UUID()
    var source: SFTPRemoteCopySource
    var jobs: [Job]
    var directories: [String]
    var directoryConflicts: Set<String>
    public var conflictCount: Int
    public var transferCount: Int { jobs.count }
    public var directoryCount: Int { directories.count }
}

public nonisolated enum SFTPRemoteCopyPlanner {
    static func manifest(
        files: [RemoteFile], client: any SFTPChannelProtocol, regularItemsOnly: Bool = false,
        cancellation: TransferCancellationToken? = nil
    ) async throws -> [SFTPRemoteManifestEntry] {
        var entries: [SFTPRemoteManifestEntry] = []
        func collect(_ file: RemoteFile, relativePath: String) async throws {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw SFTPError.cancelled }
            if regularItemsOnly {
                guard file.kind == .file || file.kind == .directory,
                    RemoteFileName.isValid(file.name), file.size >= 0
                else { throw SFTPRemoteCopySourceError(path: file.path) }
            }
            entries.append(
                SFTPRemoteManifestEntry(
                    sourcePath: file.path, relativePath: relativePath,
                    kind: file.kind, byteCount: file.size
                ))
            guard file.isDirectory else { return }
            for child in try await client.listDirectory(at: file.path) {
                if regularItemsOnly {
                    let expected = file.path == "/" ? "/\(child.name)" : "\(file.path)/\(child.name)"
                    guard child.path == expected else { throw SFTPRemoteCopySourceError(path: child.path) }
                }
                try await collect(child, relativePath: relativePath + "/" + child.name)
            }
        }
        for file in files { try await collect(file, relativePath: file.name) }
        return entries
    }

    public static func prepare(
        _ payload: SFTPRemoteItemsPayload,
        destination: String,
        client: any SFTPChannelProtocol,
        coordinator: SFTPTransferCoordinator
    ) async throws -> SFTPRemoteCopyBatch {
        let manifest = try await coordinator.remoteManifest(for: payload)
        var jobs: [SFTPRemoteCopyBatch.Job] = []
        var directories: [String] = []
        for entry in manifest.entries {
            let target = RemotePath.join(destination, entry.relativePath)
            if entry.isDirectory {
                directories.append(target)
            } else {
                jobs.append(
                    .init(
                        sourcePath: entry.sourcePath, destinationPath: target,
                        byteCount: entry.byteCount, hasConflict: false,
                        conflictingTargetIsDirectory: false
                    ))
            }
        }
        let preflight = try await SFTPRemoteConflictResolver.preflight(
            directories: directories, targets: jobs.map(\.destinationPath),
            includeConflictingRoot: true, client: client)
        for (index, kind) in zip(jobs.indices, preflight.targetKinds) {
            guard let kind else { continue }
            jobs[index].hasConflict = true
            jobs[index].conflictingTargetIsDirectory = kind
        }
        return SFTPRemoteCopyBatch(
            source: manifest.source, jobs: jobs,
            directories: preflight.directories,
            directoryConflicts: preflight.directoryConflicts,
            conflictCount: preflight.conflictCount
        )
    }

    /// Returns whether resolving the batch changed remote directories, even without file jobs.
    @discardableResult
    @MainActor public static func enqueue(
        _ batch: SFTPRemoteCopyBatch,
        policy: TransferConflictPolicy,
        destinationHostID: Host.ID,
        destinationConnection: SFTPTransferConnection,
        destinationHomeDirectory: String? = nil,
        client: any SFTPChannelProtocol,
        coordinator: SFTPTransferCoordinator,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) async throws -> Bool {
        let resolution = try await SFTPRemoteConflictResolver.resolveDirectories(
            batch.directories, conflicts: batch.directoryConflicts,
            policy: policy, client: client
        )
        for var job in batch.jobs {
            guard let destination = resolution.destination(for: job.destinationPath) else { continue }
            if destination != job.destinationPath { job.hasConflict = false }
            job.destinationPath = destination
            if job.hasConflict {
                guard
                    let resolved = try await SFTPRemoteConflictResolver.resolveConflict(
                        path: job.destinationPath,
                        conflictingTargetIsDirectory: job.conflictingTargetIsDirectory,
                        policy: policy, client: client
                    )
                else { continue }
                job.destinationPath = resolved.path
                job.hasConflict = resolved.overwrite
            }
            coordinator.enqueueRemoteCopy(
                batchID: batch.id,
                sourcePath: job.sourcePath,
                sourceHostID: batch.source.hostID,
                sourceConnection: batch.source.connection,
                destinationPath: job.destinationPath,
                destinationHostID: destinationHostID,
                destinationConnection: destinationConnection,
                byteCount: job.byteCount,
                overwrite: job.hasConflict && policy == .replace,
                sourceHomeDirectory: batch.source.homeDirectory,
                destinationHomeDirectory: destinationHomeDirectory,
                completion: completion
            )
        }
        return resolution.changed
    }

}
