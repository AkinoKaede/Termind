import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized)
@MainActor
struct MobileSFTPHistoryTests {
    @Test func deletingAHistoryEntryUpdatesThePresentedList() async throws {
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        let library = HostLibraryModel(hosts: [host])
        let history = SFTPHistoryModel()
        history.record(kind: .directory, path: "/srv", for: host.id)
        history.record(kind: .file, path: "/srv/report.txt", for: host.id)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            sftpHistory: history
        )
        let controller = UIHostingController(
            rootView: MobileSFTPHistoryView(workspace: workspace, open: { _ in })
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(visibleCells(in: controller.view).count == 2)

        let newest = try #require(history.entries(for: host.id).first)
        history.delete(newest.id)
        try await Task.sleep(for: .milliseconds(300))

        #expect(visibleCells(in: controller.view).count == 1)
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
