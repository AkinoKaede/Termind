// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated protocol RemoteFileSystem: Sendable {
    func listDirectory(at path: String) async throws -> [RemoteFile]
    func attributes(at path: String) async throws -> RemoteFile?
    func readFile(at path: String, maximumBytes: Int) async throws -> Data
    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws
    func setPermissions(at path: String, to permissions: UInt32) async throws
    func createDirectory(at path: String) async throws
    func rename(from source: String, to destination: String, overwrite: Bool) async throws
    func removeFile(at path: String) async throws
    func removeDirectory(at path: String) async throws
}

public nonisolated enum RemoteFileName {
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

nonisolated extension RemoteFileSystem {
    public func directoryContents(at path: String) async throws -> [RemoteFile] {
        try await listDirectory(at: path).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func createDirectory(named name: String, in directory: String) async throws {
        guard RemoteFileName.isValid(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try await createDirectory(at: RemotePath.join(directory, name))
    }

    public func rename(_ file: RemoteFile, to name: String) async throws {
        guard RemoteFileName.isValid(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try await rename(
            from: file.path,
            to: RemotePath.join(RemotePath.parent(of: file.path), name),
            overwrite: false
        )
    }

    public func setPermissions(of file: RemoteFile, to permissions: UInt32) async throws {
        try await setPermissions(at: file.path, to: permissions & 0o7777)
    }

    public func remove(_ file: RemoteFile) async throws {
        if file.isDirectory {
            try await removeDirectory(at: file.path)
        } else {
            try await removeFile(at: file.path)
        }
    }
}
