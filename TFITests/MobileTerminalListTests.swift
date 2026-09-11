import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileTerminalListTests {
    @Test func snippetsAndHistoryMountListViewKitRows() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        app.library.upsert(Snippet(title: "List files", body: "ls -la"))
        app.commandHistory.record("pwd", for: host.id)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library,
            commandHistory: app.commandHistory)

        try await withHostedView(MobileTerminalSnippetsView(library: app.library, workspace: workspace)) { root in
            let rows = descendants(of: MobileHostingListRow.self, in: root.view).filter { !$0.isHidden }
            #expect(rows.count == 1)
            #expect(rows.first?.accessibilityCustomActions == nil)
        }

        try await withHostedView(MobileCommandHistoryView(workspace: workspace)) { root in
            let row = try #require(
                descendants(of: MobileHostingListRow.self, in: root.view).first { !$0.isHidden })
            #expect(row.accessibilityCustomActions?.map(\.name).contains(String(localized: "Delete")) == true)
            row.prepareForReuse()
            #expect(row.accessibilityCustomActions == nil)
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
