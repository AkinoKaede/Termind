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
        app.library.upsert(Snippet(title: "List files", body: "ls -la\npwd"))
        app.commandHistory.record("pwd", for: host.id)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library,
            commandHistory: app.commandHistory)

        try await withHostedView(MobileTerminalSnippetsView(library: app.library, workspace: workspace)) { root in
            let rows = descendants(of: MobileHostingListRow.self, in: root.view).filter { !$0.isHidden }
            #expect(rows.count == 1)
            #expect(rows.first?.accessibilityCustomActions == nil)
            #expect(rows.first?.backgroundColor == .secondarySystemGroupedBackground)
            let list = descendants(of: UIScrollView.self, in: root.view).first {
                String(reflecting: type(of: $0)).contains("ListViewKit.ListView")
            }
            #expect(list?.backgroundColor == .systemGroupedBackground)
        }

        try await withHostedView(MobileCommandHistoryView(workspace: workspace)) { root in
            let row = try #require(
                descendants(of: MobileHostingListRow.self, in: root.view).first { !$0.isHidden })
            #expect(row.accessibilityCustomActions?.map(\.name).contains(String(localized: "Delete")) == true)
            #expect(row.backgroundColor == .secondarySystemGroupedBackground)
            let deleteButton = try #require(
                descendants(of: UIButton.self, in: row).first {
                    $0.accessibilityLabel == String(localized: "Delete")
                })
            row.layoutIfNeeded()
            #expect(deleteButton.configuration == nil)
            #expect(deleteButton.backgroundColor == .systemRed)
            #expect(deleteButton.tintColor == .white)
            #expect(deleteButton.currentImage != nil)
            #expect(deleteButton.frame.width == MobileHostingListRow.deleteWidth)
            #expect(deleteButton.frame.height == row.bounds.height)
            #expect(deleteButton.frame.maxX == row.bounds.maxX)
            row.prepareForReuse()
            #expect(row.accessibilityCustomActions == nil)
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

    @Test func terminalListsUseCompactSidebarContentAndSingleClickInsertion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let history = try String(
            contentsOf: root.appending(path: "TFI/Features/Terminal/MobileCommandHistoryView.swift"),
            encoding: .utf8)
        let snippets = try String(
            contentsOf: root.appending(path: "TFI/Features/Terminal/MobileTerminalSnippetsView.swift"),
            encoding: .utf8)

        #expect(history.contains("onSelect: insert"))
        #expect(history.contains(".lineLimit(2)"))
        #expect(!history.contains("Exit Status"))
        #expect(history.contains("MobileTerminalRiskIndicator"))
        let bodyStart = try #require(snippets.range(of: "Text(snippet.body)"))
        let bodyEnd = try #require(snippets[bodyStart.upperBound...].range(of: "Spacer(minLength: 8)"))
        let bodyPreview = snippets[bodyStart.lowerBound..<bodyEnd.lowerBound]
        #expect(bodyPreview.contains(".lineLimit(1)"))
        #expect(bodyPreview.contains(".truncationMode(.tail)"))
        #expect(snippets.contains("estimatedRowHeight: 60"))
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
