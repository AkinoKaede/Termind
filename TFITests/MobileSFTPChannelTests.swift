import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileSFTPChannelTests {
    @Test func navigationNormalizesPathsAndMaintainsBackwardAndForwardHistory() async throws {
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [remoteFile("/home/readme.md")],
                "/etc": [remoteFile("/etc/hosts")],
                "/srv": [remoteFile("/srv/releases", kind: .directory)],
                "/tmp": [],
            ])
        let channel = MobileSFTPChannelModel()
        try await attach(channel, to: fileSystem, path: "/home/")

        #expect(channel.path == "/home")
        #expect(channel.pathText == "/home")
        #expect(!channel.canGoBack && !channel.canGoForward)

        await channel.openDirectory(" /etc/./ ")
        await channel.openDirectory("/srv")
        #expect(channel.path == "/srv")
        #expect(channel.backHistory == ["/home", "/etc"])

        await channel.goBack()
        #expect(channel.path == "/etc")
        #expect(channel.canGoBack && channel.canGoForward)
        await channel.goForward()
        #expect(channel.path == "/srv")

        await channel.goBack()
        await channel.openDirectory("/tmp")
        #expect(channel.path == "/tmp")
        #expect(!channel.canGoForward)
    }

    @Test func refreshAndFailedNavigationDoNotMutateHistoryOrDisplayedPath() async throws {
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [remoteFile("/home/a")],
                "/srv": [remoteFile("/srv/b")],
            ])
        let channel = MobileSFTPChannelModel()
        try await attach(channel, to: fileSystem, path: "/home")
        await channel.openDirectory("/srv")
        let history = channel.backHistory

        await channel.reload()
        await channel.openDirectory("/srv")
        #expect(channel.path == "/srv")
        #expect(channel.backHistory == history)

        await channel.openDirectory("/missing")
        #expect(channel.path == "/srv")
        #expect(channel.backHistory == history)
        #expect(channel.operationError == "Missing /missing")
    }

    @Test func searchFiltersTheCurrentDirectoryWithoutChangingItsStableOrder() async throws {
        let folder = remoteFile("/home/Reports", kind: .directory)
        let report = remoteFile("/home/report.txt")
        let notes = remoteFile("/home/notes.txt")
        let fileSystem = MobileBrowserFileSystem(
            listings: ["/home": [notes, report, folder]])
        let channel = MobileSFTPChannelModel()
        try await attach(channel, to: fileSystem, path: "/home")

        #expect(channel.files == [folder, notes, report])
        channel.query = "REPORT"
        #expect(channel.visibleFiles == [folder, report])
        channel.query = ""
        #expect(channel.visibleFiles == [folder, notes, report])
    }

    @Test func hiddenFilesAreExcludedByDefaultAndCanBeShownWithinTheSession() async throws {
        let hiddenFolder = remoteFile("/home/.cache", kind: .directory)
        let visibleFolder = remoteFile("/home/Reports", kind: .directory)
        let hiddenFile = remoteFile("/home/.env")
        let hiddenLink = remoteFile("/home/.current", kind: .symbolicLink)
        let visibleFile = remoteFile("/home/report.txt")
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [visibleFile, hiddenFile, visibleFolder, hiddenFolder, hiddenLink],
                "/srv": [remoteFile("/srv/.ssh", kind: .directory)],
            ])
        let channel = MobileSFTPChannelModel()
        try await attach(channel, to: fileSystem, path: "/home")

        #expect(!channel.showsHiddenFiles)
        #expect(channel.visibleFiles == [visibleFolder, visibleFile])

        channel.query = "ENV"
        #expect(channel.visibleFiles.isEmpty)
        channel.showsHiddenFiles = true
        #expect(channel.visibleFiles == [hiddenFile])

        channel.query = ""
        #expect(Set(channel.visibleFiles) == Set([hiddenFolder, visibleFolder, hiddenFile, hiddenLink, visibleFile]))
        #expect(channel.visibleFiles.prefix(2).allSatisfy { $0.isDirectory })

        await channel.openDirectory("/srv")
        await channel.reload()
        #expect(channel.showsHiddenFiles)
        #expect(channel.visibleFiles.map(\.name) == [".ssh"])

        channel.detach()
        try await attach(channel, to: fileSystem, path: "/home")
        #expect(channel.showsHiddenFiles)

        channel.showsHiddenFiles = false
        #expect(channel.visibleFiles == [visibleFolder, visibleFile])
    }

    @Test func sortMatchesDesktopDefaultsAndKeepsDirectoriesBeforeFiles() async throws {
        let older = RemoteFile(
            path: "/home/older.txt", name: "older.txt", kind: .file, size: 1_000,
            modifiedAt: Date(timeIntervalSince1970: 10), permissions: 0o644,
            ownerUID: 501, ownerGID: 20
        )
        let newer = RemoteFile(
            path: "/home/newer.txt", name: "newer.txt", kind: .file, size: 10,
            modifiedAt: Date(timeIntervalSince1970: 20), permissions: 0o644,
            ownerUID: 501, ownerGID: 20
        )
        let folder = remoteFile("/home/folder", kind: .directory)
        let channel = MobileSFTPChannelModel()
        try await attach(
            channel,
            to: MobileBrowserFileSystem(listings: ["/home": [older, newer, folder]]),
            path: "/home"
        )

        channel.sort(by: .modified)
        #expect(channel.sortDirection == .descending)
        #expect(channel.visibleFiles.map(\.name) == ["folder", "newer.txt", "older.txt"])
        channel.sort(by: .modified)
        #expect(channel.sortDirection == .ascending)
        #expect(channel.visibleFiles.map(\.name) == ["folder", "older.txt", "newer.txt"])
        channel.sort(by: .size)
        #expect(channel.sortDirection == .descending)
        #expect(channel.visibleFiles.map(\.name) == ["folder", "older.txt", "newer.txt"])
    }

    @Test func parentNavigationItemIsPrependedAfterFileSorting() {
        let files = [remoteFile("/home/z.txt"), remoteFile("/home/a.txt")]
        let sorted = files.sorted { $0.name < $1.name }

        let items = mobileSFTPListItems(path: "/home", files: sorted)

        guard case .parent("/") = items.first else {
            Issue.record("The parent navigation item must remain first")
            return
        }
        let names = items.dropFirst().compactMap { item in
            if case .file(let file) = item { file.name } else { nil }
        }
        #expect(names == ["a.txt", "z.txt"])
        #expect(mobileSFTPListItems(path: "/", files: sorted).count == sorted.count)
    }

    @Test func successfulDirectoriesRefreshSessionHistoryAndFailuresDoNot() async throws {
        let history = SFTPHistoryModel()
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [],
                "/srv": [],
            ])
        let channel = MobileSFTPChannelModel(history: history)
        try await attach(channel, to: fileSystem, path: "/home/")

        await channel.openDirectory("/srv")
        await channel.reload()
        #expect(history.entries().map(\.path) == ["/srv", "/home"])

        await channel.openDirectory("/missing")
        #expect(history.entries().map(\.path) == ["/srv", "/home"])
    }

    @Test func staleDirectoryResponseDoesNotCreateHistory() async throws {
        let history = SFTPHistoryModel()
        let staleFileSystem = MobileDeferredFileSystem()
        let currentFileSystem = MobileBrowserFileSystem(listings: ["/current": []])
        let channel = MobileSFTPChannelModel(history: history)
        let staleGeneration = UUID()

        let staleAttach = Task {
            try? await channel.attach(
                fileSystem: staleFileSystem,
                path: "/stale",
                connectionGeneration: staleGeneration,
                handlesConnectionError: { _ in false },
                didChangePath: {}
            )
        }
        await staleFileSystem.waitUntilRequested()
        try await channel.attach(
            fileSystem: currentFileSystem,
            path: "/current",
            connectionGeneration: UUID(),
            handlesConnectionError: { _ in false },
            didChangePath: {}
        )
        await staleFileSystem.succeed()
        await staleAttach.value

        #expect(channel.path == "/current")
        #expect(history.entries().map(\.path) == ["/current"])
    }

    private func attach(
        _ channel: MobileSFTPChannelModel,
        to fileSystem: MobileBrowserFileSystem,
        path: String
    ) async throws {
        try await channel.attach(
            fileSystem: fileSystem,
            path: path,
            connectionGeneration: UUID(),
            handlesConnectionError: { _ in false },
            didChangePath: {}
        )
    }

    private func remoteFile(_ path: String, kind: RemoteFile.Kind = .file) -> RemoteFile {
        RemoteFile(
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: kind,
            size: 0,
            permissions: 0o644,
            ownerUID: 501,
            ownerGID: 20
        )
    }
}

private actor MobileBrowserFileSystem: RemoteFileSystem {
    let listings: [String: [RemoteFile]]

    init(listings: [String: [RemoteFile]]) {
        self.listings = listings
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        guard let files = listings[path] else {
            throw MobileBrowserFileSystemError.missing(path)
        }
        return files
    }

    func attributes(at _: String) async throws -> RemoteFile? { nil }
    func readFile(at _: String, maximumBytes _: Int) async throws -> Data { Data() }
    func writeFile(_: Data, at _: String, overwrite _: Bool) async throws {}
    func setPermissions(at _: String, to _: UInt32) async throws {}
    func createDirectory(at _: String) async throws {}
    func rename(from _: String, to _: String, overwrite _: Bool) async throws {}
    func removeFile(at _: String) async throws {}
    func removeDirectory(at _: String) async throws {}
}

private actor MobileDeferredFileSystem: RemoteFileSystem {
    private var requested = false
    private var continuation: CheckedContinuation<[RemoteFile], any Error>?

    func waitUntilRequested() async {
        while !requested { await Task.yield() }
    }

    func succeed() {
        continuation?.resume(returning: [])
        continuation = nil
    }

    func listDirectory(at _: String) async throws -> [RemoteFile] {
        requested = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func attributes(at _: String) async throws -> RemoteFile? { nil }
    func readFile(at _: String, maximumBytes _: Int) async throws -> Data { Data() }
    func writeFile(_: Data, at _: String, overwrite _: Bool) async throws {}
    func setPermissions(at _: String, to _: UInt32) async throws {}
    func createDirectory(at _: String) async throws {}
    func rename(from _: String, to _: String, overwrite _: Bool) async throws {}
    func removeFile(at _: String) async throws {}
    func removeDirectory(at _: String) async throws {}
}

private enum MobileBrowserFileSystemError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): "Missing \(path)"
        }
    }
}
