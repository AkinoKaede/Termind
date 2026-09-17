import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct SFTPRemoteConflictResolverTests {
    @Test(arguments: [false, true])
    func preflightPreservesTheCallersRootCountingRule(includeRoot: Bool) async throws {
        let root = "/dest/folder"
        let client = RemoteConflictFileSystem(files: [
            conflictFile(root), conflictFile(root + "-other", directory: true),
        ])
        let result = try await SFTPRemoteConflictResolver.preflight(
            directories: [root + "/nested", root, root],
            targets: [root, root + "/nested/file", root + "-other"],
            includeConflictingRoot: includeRoot, client: client)
        let expectedKinds: [Bool?] = includeRoot ? [nil, nil, true] : [false, nil, true]
        #expect(result.directories == [root, root, root + "/nested"])
        #expect(result.directoryConflicts == [root])
        #expect(result.targetKinds == expectedKinds)
        #expect(result.conflictCount == (includeRoot ? 2 : 4))
        let expectedCalls: [RemoteConflictCall] =
            includeRoot
            ? [.attributes(root), .attributes(root + "-other")]
            : [.attributes(root), .attributes(root), .attributes(root), .attributes(root + "-other")]
        #expect(await client.operations == expectedCalls)
    }

    @Test(arguments: [TransferConflictPolicy.skip, .replace, .keepBoth])
    func directoryPoliciesPreserveSubtreeMappingAndMutationAccounting(policy: TransferConflictPolicy) async throws {
        let root = "/dest/folder"
        let client = RemoteConflictFileSystem(files: [conflictFile(root), conflictFile(root + ".2", directory: true)])
        let result = try await SFTPRemoteConflictResolver.resolveDirectories(
            [root, root + "/nested"], conflicts: [root], policy: policy, client: client)
        #expect(result.destination(for: root + "-other/file") == root + "-other/file")
        switch policy {
        case .skip:
            #expect(result.skipped == [root])
            #expect(result.destination(for: root + "/nested/file") == nil)
            #expect(result.created.isEmpty)
            #expect(!result.changed)
            #expect(await client.operations.isEmpty)
        case .replace:
            #expect(result.mappings.isEmpty)
            #expect(result.created == [root, root + "/nested"])
            #expect(result.destination(for: root + "/nested/file") == root + "/nested/file")
            #expect(result.changed)
            #expect(await client.operations.first == .removeFile(root))
        case .keepBoth:
            #expect(result.mappings.map(\.0) == [root])
            #expect(result.mappings.map(\.1) == [root + ".3"])
            #expect(result.created == [root + ".3", root + ".3/nested"])
            #expect(result.destination(for: root + "/nested/file") == root + ".3/nested/file")
            #expect(result.changed)
            #expect(try await client.attributes(at: root)?.isDirectory == false)
        }
    }

    @Test(arguments: [TransferConflictPolicy.skip, .replace, .keepBoth])
    func filePoliciesPreserveOverwriteAndExtensionAwareKeepBoth(policy: TransferConflictPolicy) async throws {
        let path = "/dest/report.tar.gz"
        let client = RemoteConflictFileSystem(files: [conflictFile(path), conflictFile("/dest/report.tar.2.gz")])
        let result = try await SFTPRemoteConflictResolver.resolveConflict(
            path: path, conflictingTargetIsDirectory: false, policy: policy, client: client)
        switch policy {
        case .skip:
            #expect(result == nil)
            #expect(await client.operations.isEmpty)
        case .replace:
            #expect(result?.path == path)
            #expect(result?.overwrite == true)
            #expect(await client.operations.isEmpty)
        case .keepBoth:
            #expect(result?.path == "/dest/report.tar.3.gz")
            #expect(result?.overwrite == false)
            #expect(
                await client.operations == [.attributes("/dest/report.tar.2.gz"), .attributes("/dest/report.tar.3.gz")])
        }
    }

    @Test(arguments: ["/dest/folder", "/"])
    func replacingADirectoryDeletesItsChildrenBeforeTheirParents(root: String) async throws {
        let first = RemotePath.join(root, "a")
        let nested = RemotePath.join(root, "nested")
        let second = RemotePath.join(nested, "b")
        let client = RemoteConflictFileSystem(files: [
            conflictFile(root, directory: true), conflictFile(first),
            conflictFile(nested, directory: true), conflictFile(second),
        ])
        let result = try await SFTPRemoteConflictResolver.resolveConflict(
            path: root, conflictingTargetIsDirectory: true, policy: .replace, client: client)
        #expect(result?.path == root)
        #expect(result?.overwrite == true)
        #expect(
            await client.operations == [
                .attributes(root), .list(root), .removeFile(first), .list(nested),
                .removeFile(second), .removeDirectory(nested), .removeDirectory(root),
            ])
    }

    @Test(arguments: [
        conflictFile("/outside/file"),
        conflictFile("/dest/folder/..", name: ".."),
        conflictFile("/dest/folder/bad\nname", name: "bad\nname"),
    ])
    func replacingADirectoryRejectsUnsafeChildrenWithoutDeletingThem(child: RemoteFile) async throws {
        let root = "/dest/folder"
        let client = RemoteConflictFileSystem(files: [conflictFile(root, directory: true)], children: [root: [child]])
        do {
            _ = try await SFTPRemoteConflictResolver.resolveConflict(
                path: root, conflictingTargetIsDirectory: true, policy: .replace, client: client)
            Issue.record("Expected unsafe remote entry rejection")
        } catch let error as SFTPRemoteCopySourceError {
            #expect(error.path == child.path)
        }
        #expect(await client.operations == [.attributes(root), .list(root)])
    }

    @Test(arguments: ["directories", "name-search", "recursive-delete"])
    func cancellationStopsAtTheExistingCopyCheckpoints(point: String) async {
        let root = "/dest/report"
        let cancelOn: RemoteConflictCall? =
            switch point {
            case "name-search": .attributes(root + ".2")
            case "recursive-delete": .list(root)
            default: nil
            }
        let client = RemoteConflictFileSystem(
            files: [conflictFile(root, directory: true), conflictFile(root + "/child"), conflictFile(root + ".2")],
            cancelOn: cancelOn)
        let task = Task {
            switch point {
            case "directories":
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await SFTPRemoteConflictResolver.resolveDirectories(
                    [root], conflicts: [root], policy: .replace, client: client)
            case "name-search":
                _ = try await SFTPRemoteConflictResolver.resolveConflict(
                    path: root, conflictingTargetIsDirectory: false, policy: .keepBoth, client: client)
            default:
                _ = try await SFTPRemoteConflictResolver.resolveConflict(
                    path: root, conflictingTargetIsDirectory: true, policy: .replace, client: client)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let expectedCalls: [RemoteConflictCall] =
            switch point {
            case "name-search": [.attributes(root + ".2")]
            case "recursive-delete": [.attributes(root), .list(root)]
            default: []
            }
        #expect(await client.operations == expectedCalls)
    }

    @Test
    func anExistingDirectoryDoesNotReportAMutation() async throws {
        let root = "/dest/folder"
        let client = RemoteConflictFileSystem(files: [conflictFile(root, directory: true)])
        let result = try await SFTPRemoteConflictResolver.resolveDirectories(
            [root], conflicts: [], policy: .replace, client: client)
        #expect(!result.changed)
        #expect(result.created.isEmpty)
        #expect(result.destination(for: root + "/file") == root + "/file")
    }
}

private nonisolated enum RemoteConflictCall: Equatable, Sendable {
    case attributes(String)
    case list(String)
    case createDirectory(String)
    case removeFile(String)
    case removeDirectory(String)
}

private nonisolated func conflictFile(_ path: String, directory: Bool = false, name: String? = nil) -> RemoteFile {
    RemoteFile(
        path: path, name: name ?? URL(fileURLWithPath: path).lastPathComponent,
        kind: directory ? .directory : .file, size: directory ? 0 : 1,
        permissions: directory ? 0o755 : 0o644, ownerUID: 501, ownerGID: 20)
}

private actor RemoteConflictFileSystem: RemoteFileSystem {
    private var files: [String: RemoteFile]
    private let children: [String: [RemoteFile]]
    private let cancelOn: RemoteConflictCall?
    private(set) var operations: [RemoteConflictCall] = []

    init(files: [RemoteFile], children: [String: [RemoteFile]] = [:], cancelOn: RemoteConflictCall? = nil) {
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        self.children = children
        self.cancelOn = cancelOn
    }

    func attributes(at path: String) async throws -> RemoteFile? {
        record(.attributes(path))
        return files[path]
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        record(.list(path))
        return children[path]
            ?? files.values.filter { $0.path != path && RemotePath.parent(of: $0.path) == path }
            .sorted { $0.path < $1.path }
    }

    func createDirectory(at path: String) async throws {
        record(.createDirectory(path))
        guard files[path] == nil else { throw FixtureError.unexpectedCall }
        files[path] = conflictFile(path, directory: true)
    }

    func removeFile(at path: String) async throws {
        record(.removeFile(path))
        guard files[path]?.isDirectory == false else { throw FixtureError.unexpectedCall }
        files[path] = nil
    }

    func removeDirectory(at path: String) async throws {
        record(.removeDirectory(path))
        let prefix = path == "/" ? "/" : path + "/"
        guard files[path]?.isDirectory == true, !files.keys.contains(where: { $0 != path && $0.hasPrefix(prefix) })
        else {
            throw FixtureError.unexpectedCall
        }
        files[path] = nil
    }

    func readFile(at path: String, maximumBytes: Int) async throws -> Data { throw FixtureError.unexpectedCall }
    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws { throw FixtureError.unexpectedCall }
    func setPermissions(at path: String, to permissions: UInt32) async throws { throw FixtureError.unexpectedCall }
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        throw FixtureError.unexpectedCall
    }

    private func record(_ operation: RemoteConflictCall) {
        operations.append(operation)
        if operation == cancelOn { withUnsafeCurrentTask { $0?.cancel() } }
    }

    private enum FixtureError: Error { case unexpectedCall }
}
