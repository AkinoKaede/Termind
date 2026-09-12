import Foundation
import TermindApplication
import TermindDomain
import Testing
import UIKit

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

private enum MobileBrowserFileSystemError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): "Missing \(path)"
        }
    }
}
