import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileTerminalListTests {
    @Test func deletingAnEndpointUpdatesTheNativeHistoryList() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        app.commandHistory.record("pwd", for: host.id)
        app.commandHistory.record("whoami", for: host.id)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library,
            commandHistory: app.commandHistory)

        try await withHostedView(MobileCommandHistoryView(library: app.library, workspace: workspace)) { root in
            #expect(nativeVisibleCells(in: root.view).count == 2)

            let newest = try #require(app.commandHistory.entries(for: host.id).first)
            app.commandHistory.delete(newest.id)
            try await Task.sleep(for: .milliseconds(300))

            #expect(nativeVisibleCells(in: root.view).count == 1)
        }
    }

    @Test func retainedHistoryKeepsOnlyTheNativeViewportMounted() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let history = CommandHistoryModel(
            entries: (0..<CommandHistoryModel.perHostLimit).map { index in
                CommandHistoryEntry(
                    hostID: host.id, command: "printf '%04d' \(index)",
                    executedAt: Date(timeIntervalSince1970: TimeInterval(index)))
            })
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library,
            commandHistory: history)

        try await withHostedView(MobileCommandHistoryView(library: app.library, workspace: workspace)) { root in
            #expect(history.entries(for: host.id).count == CommandHistoryModel.perHostLimit)
            let cells = nativeVisibleCells(in: root.view)
            #expect(!cells.isEmpty)
            #expect(cells.count < 50)
        }
    }

    private func withHostedView<Content: View>(
        _ content: Content, check: (UIViewController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        try await check(controller)
    }

    private func nativeVisibleCells(in root: UIView) -> [UIView] {
        let collectionCells = descendants(of: UICollectionViewCell.self, in: root)
        let tableCells = descendants(of: UITableViewCell.self, in: root)
        return (collectionCells.map { $0 as UIView } + tableCells.map { $0 as UIView })
            .filter { !$0.isHidden && $0.window != nil }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = []
        var pending = [root]
        while let next = pending.popLast() {
            if let match = next as? T { result.append(match) }
            pending.append(contentsOf: next.subviews)
        }
        return result
    }
}
