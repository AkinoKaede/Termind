import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileTerminalListTests {
    @Test func snippetsAndHistoryMountNativeSwiftUILists() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        app.library.upsert(Snippet(title: "List files", body: "ls -la\npwd"))
        app.commandHistory.record("pwd", for: host.id)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library,
            commandHistory: app.commandHistory)

        try await withHostedView(MobileTerminalSnippetsView(library: app.library, workspace: workspace)) { root in
            expectNativeList(in: root.view)
        }

        try await withHostedView(MobileCommandHistoryView(workspace: workspace)) { root in
            expectNativeList(in: root.view)
        }
    }

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

        try await withHostedView(MobileCommandHistoryView(workspace: workspace)) { root in
            #expect(nativeVisibleCells(in: root.view).count == 2)

            let newest = try #require(app.commandHistory.entries(for: host.id).first)
            app.commandHistory.delete(newest.id)
            try await Task.sleep(for: .milliseconds(300))

            #expect(nativeVisibleCells(in: root.view).count == 1)
        }
    }

    @Test func thousandRowHistoryKeepsOnlyTheNativeViewportMounted() async throws {
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

        try await withHostedView(MobileCommandHistoryView(workspace: workspace)) { root in
            #expect(history.entries(for: host.id).count == CommandHistoryModel.perHostLimit)
            let cells = nativeVisibleCells(in: root.view)
            #expect(!cells.isEmpty)
            #expect(cells.count < 50)
        }
    }

    @Test func nativeHistoryRemeasuresForAccessibilityDynamicType() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        app.commandHistory.record("echo a command that needs two lines in the compact sheet", for: host.id)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library,
            commandHistory: app.commandHistory)

        try await withHostedView(
            MobileCommandHistoryView(workspace: workspace)
                .environment(\.dynamicTypeSize, .accessibility3)
        ) { root in
            let cell = try #require(nativeVisibleCells(in: root.view).first)
            #expect(cell.bounds.height > 100)
        }
    }

    @Test func terminalRiskIndicatorsShareTheCompactPalette() {
        #expect(MobileTerminalRiskIndicator.color(for: .safe) == .systemGreen)
        #expect(MobileTerminalRiskIndicator.color(for: .caution) == .systemOrange)
        #expect(MobileTerminalRiskIndicator.color(for: .destructive) == .systemRed)
        #expect(MobileTerminalRiskIndicator.accessibilityIdentifier(for: .safe) == "TerminalRisk.safe")
        #expect(MobileTerminalRiskIndicator.accessibilityIdentifier(for: .caution) == "TerminalRisk.caution")
        #expect(MobileTerminalRiskIndicator.accessibilityIdentifier(for: .destructive) == "TerminalRisk.destructive")
    }

    @Test func terminalListsUseNativeActionsAndCompactContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let history = try String(
            contentsOf: root.appending(path: "TFI/Features/Terminal/MobileCommandHistoryView.swift"),
            encoding: .utf8)
        let snippets = try String(
            contentsOf: root.appending(path: "TFI/Features/Terminal/MobileTerminalSnippetsView.swift"),
            encoding: .utf8)

        #expect(history.contains("List(entries)"))
        #expect(history.contains(".listStyle(.insetGrouped)"))
        #expect(history.contains(".contextMenu"))
        #expect(history.contains(".swipeActions(edge: .trailing, allowsFullSwipe: true)"))
        #expect(history.contains(".disabled(!workspace.connected)"))
        #expect(!history.contains("MobileNativeList("))
        #expect(history.contains(".lineLimit(2)"))
        #expect(!history.contains("Exit Status"))
        #expect(history.contains("MobileTerminalRiskIndicator"))

        let bodyStart = try #require(snippets.range(of: "Text(snippet.body)"))
        let bodyEnd = try #require(snippets[bodyStart.upperBound...].range(of: "Spacer(minLength: 8)"))
        let bodyPreview = snippets[bodyStart.lowerBound..<bodyEnd.lowerBound]
        #expect(snippets.contains("List(snippets)"))
        #expect(snippets.contains(".listStyle(.insetGrouped)"))
        #expect(snippets.contains(".contextMenu"))
        #expect(snippets.contains(".disabled(!workspace.connected)"))
        #expect(!snippets.contains("MobileNativeList("))
        #expect(bodyPreview.contains(".lineLimit(1)"))
        #expect(bodyPreview.contains(".truncationMode(.tail)"))
        #expect(snippets.contains("MobileTerminalRiskIndicator"))
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

    private func expectNativeList(in root: UIView) {
        let legacyList = descendants(of: UIScrollView.self, in: root).first {
            String(reflecting: type(of: $0)).contains("ListViewKit.ListView")
        }
        #expect(legacyList == nil)
        #expect(descendants(of: MobileHostingListRow.self, in: root).isEmpty)
        #expect(!nativeVisibleCells(in: root).isEmpty)
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
