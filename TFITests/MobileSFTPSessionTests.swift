import Foundation
import TermindApplication
import TermindDomain
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileSFTPSessionTests {
    @Test func navigationNormalizesPathsAndMaintainsBackwardAndForwardHistory() async throws {
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [remoteFile("/home/readme.md")],
                "/etc": [remoteFile("/etc/hosts")],
                "/srv": [remoteFile("/srv/releases", kind: .directory)],
                "/tmp": [],
            ])
        let session = MobileSFTPSessionModel()
        try await attach(session, to: fileSystem, path: "/home/")

        #expect(session.path == "/home")
        #expect(session.pathText == "/home")
        #expect(!session.canGoBack && !session.canGoForward)

        await session.openDirectory(" /etc/./ ")
        await session.openDirectory("/srv")
        #expect(session.path == "/srv")
        #expect(session.backHistory == ["/home", "/etc"])

        await session.goBack()
        #expect(session.path == "/etc")
        #expect(session.canGoBack && session.canGoForward)
        await session.goForward()
        #expect(session.path == "/srv")

        await session.goBack()
        await session.openDirectory("/tmp")
        #expect(session.path == "/tmp")
        #expect(!session.canGoForward)
    }

    @Test func refreshAndFailedNavigationDoNotMutateHistoryOrDisplayedPath() async throws {
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [remoteFile("/home/a")],
                "/srv": [remoteFile("/srv/b")],
            ])
        let session = MobileSFTPSessionModel()
        try await attach(session, to: fileSystem, path: "/home")
        await session.openDirectory("/srv")
        let history = session.backHistory

        await session.reload()
        await session.openDirectory("/srv")
        #expect(session.path == "/srv")
        #expect(session.backHistory == history)

        await session.openDirectory("/missing")
        #expect(session.path == "/srv")
        #expect(session.backHistory == history)
        #expect(session.operationError == "Missing /missing")
    }

    @Test func searchFiltersTheCurrentDirectoryWithoutChangingItsStableOrder() async throws {
        let folder = remoteFile("/home/Reports", kind: .directory)
        let report = remoteFile("/home/report.txt")
        let notes = remoteFile("/home/notes.txt")
        let fileSystem = MobileBrowserFileSystem(
            listings: ["/home": [notes, report, folder]])
        let session = MobileSFTPSessionModel()
        try await attach(session, to: fileSystem, path: "/home")

        #expect(session.files == [folder, notes, report])
        session.query = "REPORT"
        #expect(session.visibleFiles == [folder, report])
        session.query = ""
        #expect(session.visibleFiles == [folder, notes, report])
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
        let session = MobileSFTPSessionModel()
        try await attach(session, to: fileSystem, path: "/home")

        #expect(!session.showsHiddenFiles)
        #expect(session.visibleFiles == [visibleFolder, visibleFile])

        session.query = "ENV"
        #expect(session.visibleFiles.isEmpty)
        session.showsHiddenFiles = true
        #expect(session.visibleFiles == [hiddenFile])

        session.query = ""
        #expect(Set(session.visibleFiles) == Set([hiddenFolder, visibleFolder, hiddenFile, hiddenLink, visibleFile]))
        #expect(session.visibleFiles.prefix(2).allSatisfy { $0.isDirectory })

        await session.openDirectory("/srv")
        await session.reload()
        #expect(session.showsHiddenFiles)
        #expect(session.visibleFiles.map(\.name) == [".ssh"])

        session.detach()
        try await attach(session, to: fileSystem, path: "/home")
        #expect(session.showsHiddenFiles)

        session.showsHiddenFiles = false
        #expect(session.visibleFiles == [visibleFolder, visibleFile])
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
        let session = MobileSFTPSessionModel()
        try await attach(
            session,
            to: MobileBrowserFileSystem(listings: ["/home": [older, newer, folder]]),
            path: "/home"
        )

        session.sort(by: .modified)
        #expect(session.sortDirection == .descending)
        #expect(session.visibleFiles.map(\.name) == ["folder", "newer.txt", "older.txt"])
        session.sort(by: .modified)
        #expect(session.sortDirection == .ascending)
        #expect(session.visibleFiles.map(\.name) == ["folder", "older.txt", "newer.txt"])
        session.sort(by: .size)
        #expect(session.sortDirection == .descending)
        #expect(session.visibleFiles.map(\.name) == ["folder", "older.txt", "newer.txt"])
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

    @Test func successfulDirectoriesRefreshPersistentHistoryAndFailuresDoNot() async throws {
        let hostID = UUID()
        let history = SFTPHistoryModel()
        let fileSystem = MobileBrowserFileSystem(
            listings: [
                "/home": [],
                "/srv": [],
            ])
        let session = MobileSFTPSessionModel(hostID: hostID, history: history)
        try await attach(session, to: fileSystem, path: "/home/")

        await session.openDirectory("/srv")
        await session.reload()
        #expect(history.entries(for: hostID).map(\.path) == ["/srv", "/home"])

        await session.openDirectory("/missing")
        #expect(history.entries(for: hostID).map(\.path) == ["/srv", "/home"])
    }

    @Test func staleDirectoryResponseDoesNotCreateHistory() async throws {
        let hostID = UUID()
        let history = SFTPHistoryModel()
        let staleFileSystem = MobileDeferredFileSystem()
        let currentFileSystem = MobileBrowserFileSystem(listings: ["/current": []])
        let session = MobileSFTPSessionModel(hostID: hostID, history: history)
        let staleGeneration = UUID()

        let staleAttach = Task {
            try? await session.attach(
                fileSystem: staleFileSystem,
                path: "/stale",
                connectionGeneration: staleGeneration,
                handlesConnectionError: { _ in false },
                didChangePath: {}
            )
        }
        await staleFileSystem.waitUntilRequested()
        try await session.attach(
            fileSystem: currentFileSystem,
            path: "/current",
            connectionGeneration: UUID(),
            handlesConnectionError: { _ in false },
            didChangePath: {}
        )
        await staleFileSystem.succeed()
        await staleAttach.value

        #expect(session.path == "/current")
        #expect(history.entries(for: hostID).map(\.path) == ["/current"])
    }

    @Test func interactivePopRequiresAParentNavigationDestination() {
        let root = UIViewController()
        let controller = MobileInteractivePopGesture.Controller()
        let navigation = UINavigationController(rootViewController: root)

        #expect(!controller.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
        navigation.pushViewController(controller, animated: false)
        #expect(controller.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
    }

    private func attach(
        _ session: MobileSFTPSessionModel,
        to fileSystem: MobileBrowserFileSystem,
        path: String
    ) async throws {
        try await session.attach(
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
