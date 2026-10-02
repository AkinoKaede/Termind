import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1")) @MainActor
struct MobileTerminalListTests {
    @Test func appendingACommandUpdatesTheNativeHistoryList() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh), hosts: app.library)
        workspace.commandHistory.record("pwd")
        try await withHostedView(MobileCommandHistoryView(library: app.library, workspace: workspace)) { root in
            #expect(nativeVisibleCells(in: root.view).count == 1)
            workspace.commandHistory.record("whoami")
            try await Task.sleep(for: .milliseconds(300))
            #expect(nativeVisibleCells(in: root.view).count == 2)
        }
    }

    @Test func retainedHistoryKeepsOnlyTheNativeViewportMounted() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh), hosts: app.library)
        for index in 0..<CommandHistoryModel.perSessionLimit {
            workspace.commandHistory.record("printf '%04d' \(index)")
        }
        try await withHostedView(MobileCommandHistoryView(library: app.library, workspace: workspace)) { root in
            #expect(workspace.commandHistory.entries().count == CommandHistoryModel.perSessionLimit)
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
