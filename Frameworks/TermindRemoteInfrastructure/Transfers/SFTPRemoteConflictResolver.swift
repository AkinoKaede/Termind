// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

nonisolated enum SFTPRemoteConflictResolver {
    struct Preflight: Sendable {
        var directories: [String]
        var directoryConflicts: Set<String>
        var targetKinds: [Bool?]
        var conflictCount: Int
    }

    struct DirectoryResolution: Sendable {
        var skipped: [String] = []
        var mappings: [(String, String)] = []
        var created: [String] = []
        var changed = false

        func destination(for path: String) -> String? {
            if skipped.contains(where: { SFTPRemoteConflictResolver.contains(path, in: $0) }) { return nil }
            var destination = path
            for mapping in mappings where SFTPRemoteConflictResolver.contains(destination, in: mapping.0) {
                destination = mapping.1 + destination.dropFirst(mapping.0.count)
            }
            return destination
        }
    }

    /// Upload counts strict descendants; copy also suppresses a conflicting root itself.
    static func preflight(
        directories: [String], targets: [String], includeConflictingRoot: Bool,
        client: any RemoteFileSystem
    ) async throws -> Preflight {
        let directories = directories.sorted { $0.count < $1.count }
        var directoryConflicts: Set<String> = []
        var targetKinds: [Bool?] = []
        var conflictCount = 0
        func isBlocked(_ path: String) -> Bool {
            directoryConflicts.contains {
                (includeConflictingRoot || path != $0) && contains(path, in: $0)
            }
        }
        for directory in directories {
            if isBlocked(directory) { continue }
            if let existing = try await client.attributes(at: directory), !existing.isDirectory {
                directoryConflicts.insert(directory)
                conflictCount += 1
            }
        }
        for target in targets {
            if isBlocked(target) {
                targetKinds.append(nil)
                continue
            }
            let kind = try await client.attributes(at: target)?.isDirectory
            targetKinds.append(kind)
            if kind != nil { conflictCount += 1 }
        }
        return Preflight(
            directories: directories, directoryConflicts: directoryConflicts,
            targetKinds: targetKinds, conflictCount: conflictCount)
    }

    static func resolveDirectories(
        _ directories: [String], conflicts: Set<String>,
        policy: TransferConflictPolicy, client: any RemoteFileSystem
    ) async throws -> DirectoryResolution {
        var result = DirectoryResolution()
        for original in directories {
            try Task.checkCancellation()
            guard var destination = result.destination(for: original) else { continue }
            if conflicts.contains(original) {
                switch policy {
                case .skip:
                    result.skipped.append(original)
                    continue
                case .replace:
                    try await client.removeFile(at: original)
                    result.changed = true
                case .keepBoth:
                    destination = try await availablePath(for: original, client: client)
                    result.mappings.append((original, destination))
                }
            }
            if try await client.attributes(at: destination) == nil {
                try await client.createDirectory(at: destination)
                result.created.append(destination)
                result.changed = true
            }
        }
        return result
    }

    static func resolveConflict(
        path: String, conflictingTargetIsDirectory: Bool,
        policy: TransferConflictPolicy, client: any RemoteFileSystem
    ) async throws -> (path: String, overwrite: Bool)? {
        switch policy {
        case .skip: return nil
        case .replace:
            if conflictingTargetIsDirectory, let existing = try await client.attributes(at: path) {
                try await deleteRecursively(existing, client: client)
            }
            return (path, true)
        case .keepBoth:
            return (try await availablePath(for: path, client: client), false)
        }
    }

    private static func availablePath(for path: String, client: any RemoteFileSystem) async throws -> String {
        var index = 2
        var candidate = RemotePath.keepBothCandidate(for: path, index: index)
        while try await client.attributes(at: candidate) != nil {
            try Task.checkCancellation()
            index += 1
            candidate = RemotePath.keepBothCandidate(for: path, index: index)
        }
        return candidate
    }

    private static func deleteRecursively(_ file: RemoteFile, client: any RemoteFileSystem) async throws {
        try Task.checkCancellation()
        if file.isDirectory {
            for child in try await client.listDirectory(at: file.path) {
                let expected = file.path == "/" ? "/\(child.name)" : file.path + "/" + child.name
                guard RemoteFileName.isValid(child.name), child.path == expected else {
                    throw SFTPRemoteCopySourceError(path: child.path)
                }
                try await deleteRecursively(child, client: client)
            }
            try await client.removeDirectory(at: file.path)
        } else {
            try await client.removeFile(at: file.path)
        }
    }

    private static func contains(_ path: String, in prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }
}
