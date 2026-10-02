import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1"))
@MainActor
struct MobileSFTPHistoryTests {
    @Test func appendingAHistoryEntryUpdatesThePresentedList() async throws {
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        let library = HostLibraryModel(hosts: [host])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library)
        let history = workspace.sftpHistory
        history.record(kind: .directory, path: "/srv")
        history.record(kind: .file, path: "/srv/report.txt")
        let controller = UIHostingController(
            rootView: MobileSFTPHistoryView(workspace: workspace, open: { _ in })
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(visibleCells(in: controller.view).count == 2)

        history.record(kind: .directory, path: "/new")
        for _ in 0..<100 where visibleCells(in: controller.view).count != 3 {
            try await Task.sleep(for: .milliseconds(20))
            controller.view.layoutIfNeeded()
        }
        #expect(history.entries().map(\.path) == ["/new", "/srv/report.txt", "/srv"])
        #expect(visibleCells(in: controller.view).count == 3)
    }

    private func visibleCells(in root: UIView) -> [UIView] {
        let collectionCells = descendants(of: UICollectionViewCell.self, in: root)
        let tableCells = descendants(of: UITableViewCell.self, in: root)
        return (collectionCells.map { $0 as UIView } + tableCells.map { $0 as UIView })
            .filter { !$0.isHidden && $0.window != nil }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { result.append(match) }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }
}
