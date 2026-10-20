// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite("Remote file system policy")
struct RemoteFileSystemTests {
    @Test func directoryContentsPlacesDirectoriesFirstAndUsesNaturalNameOrder() async throws {
        let fileSystem = RecordingRemoteFileSystem(
            files: [
                Self.remoteFile(path: "/tmp/file10", kind: .file),
                Self.remoteFile(path: "/tmp/folder", kind: .directory),
                Self.remoteFile(path: "/tmp/file2", kind: .file),
            ]
        )

        let files = try await fileSystem.directoryContents(at: "/tmp")

        #expect(files.map { $0.name } == ["folder", "file2", "file10"])
    }

    @Test func entryMutationsOwnNamePathAndPermissionRules() async throws {
        let fileSystem = RecordingRemoteFileSystem()
        let file = Self.remoteFile(path: "/srv/old", kind: .file)

        try await fileSystem.createDirectory(named: "new", in: "/srv")
        try await fileSystem.rename(file, to: "renamed")
        try await fileSystem.setPermissions(of: file, to: 0o17_755)
        try await fileSystem.remove(file)

        let operations = await fileSystem.operations
        #expect(
            operations == [
                .createDirectory("/srv/new"),
                .rename("/srv/old", "/srv/renamed", false),
                .setPermissions("/srv/old", 0o7_755),
                .removeFile("/srv/old"),
            ]
        )
    }

    @Test func invalidEntryNamesAreRejectedBeforeTransportAccess() async {
        let fileSystem = RecordingRemoteFileSystem()
        let file = Self.remoteFile(path: "/srv/old", kind: .file)

        await #expect(throws: CocoaError.self) {
            try await fileSystem.rename(file, to: "../escape")
        }
        #expect(await fileSystem.operations.isEmpty)
    }

    private static func remoteFile(path: String, kind: RemoteFile.Kind) -> RemoteFile {
        RemoteFile(
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: kind,
            size: 0,
            permissions: 0o644,
            ownerUID: 0,
            ownerGID: 0
        )
    }
}

private actor RecordingRemoteFileSystem: RemoteFileSystem {
    enum Operation: Equatable {
        case createDirectory(String)
        case rename(String, String, Bool)
        case setPermissions(String, UInt32)
        case removeFile(String)
        case removeDirectory(String)
    }

    private let files: [RemoteFile]
    private(set) var operations: [Operation] = []

    init(files: [RemoteFile] = []) {
        self.files = files
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] { files }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func readFile(at path: String, maximumBytes: Int) async throws -> Data { Data() }
    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {}

    func setPermissions(at path: String, to permissions: UInt32) async throws {
        operations.append(.setPermissions(path, permissions))
    }

    func createDirectory(at path: String) async throws {
        operations.append(.createDirectory(path))
    }

    func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        operations.append(.rename(source, destination, overwrite))
    }

    func removeFile(at path: String) async throws {
        operations.append(.removeFile(path))
    }

    func removeDirectory(at path: String) async throws {
        operations.append(.removeDirectory(path))
    }
}
