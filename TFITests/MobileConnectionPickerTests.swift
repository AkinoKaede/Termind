import Foundation
import SwiftUI
import TermindDomain
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileConnectionPickerTests {
    @Test func pickerDefaultsToSSHFiltersHostsAndReturnsTheSelectedProtocol() throws {
        let app = try MobileAppModel(inMemory: true)
        var selections: [(Host.ID, ConnectionHistoryEntry.Kind)] = []
        let hostModel = MobileHostPickerModel(library: app.library)
        let connectionModel = MobileConnectionPickerModel { selections.append(($0, $1)) }

        #expect(connectionModel.kind == .ssh)
        #expect(hostModel.isLibraryEmpty)

        let production = Host(name: "Production", host: "production.example.invalid")
        let staging = Host(name: "Staging", host: "staging.example.invalid")
        app.library.upsert(production)
        app.library.upsert(staging)

        #expect(!hostModel.isLibraryEmpty)
        #expect(Set(hostModel.hosts.map(\.id)) == Set([production.id, staging.id]))

        hostModel.query = "prod"
        #expect(hostModel.hosts.map(\.id) == [production.id])

        connectionModel.select(production)
        #expect(selections.count == 1)
        #expect(selections.first?.0 == production.id)
        #expect(selections.first?.1 == .ssh)

        connectionModel.kind = .sftp
        connectionModel.select(staging)
        #expect(selections.count == 2)
        #expect(selections.last?.0 == staging.id)
        #expect(selections.last?.1 == .sftp)
    }

    @Test func emptyWorkspaceHistoryKeepsTheLatestFiveValidConnectionEventsWithoutDeduplication() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        let repeatedHost = Host(name: "Repeated", host: "repeated.example.invalid")
        let otherHosts = (0..<4).map {
            Host(name: "Host \($0)", host: "host-\($0).example.invalid")
        }
        app.library.upsert(repeatedHost)
        for host in otherHosts { app.library.upsert(host) }

        let expectedEntries = try [
            #require(
                app.connectionHistory.record(kind: .ssh, for: repeatedHost.id, at: Date(timeIntervalSince1970: 70))),
            #require(
                app.connectionHistory.record(kind: .ssh, for: repeatedHost.id, at: Date(timeIntervalSince1970: 60))),
            #require(
                app.connectionHistory.record(kind: .sftp, for: otherHosts[0].id, at: Date(timeIntervalSince1970: 50))),
            #require(
                app.connectionHistory.record(kind: .ssh, for: otherHosts[1].id, at: Date(timeIntervalSince1970: 40))),
            #require(
                app.connectionHistory.record(kind: .sftp, for: otherHosts[2].id, at: Date(timeIntervalSince1970: 30))),
        ]
        _ = app.connectionHistory.record(
            kind: .ssh, for: otherHosts[3].id, at: Date(timeIntervalSince1970: 20))
        _ = app.connectionHistory.record(
            kind: .ssh, for: UUID(), at: Date(timeIntervalSince1970: 80))

        let rows = MobileWorkspaceListView(app: app, scene: scene).historyRows

        #expect(rows.count == MobileWorkspaceListView.historyLimit)
        #expect(rows.map(\.entry.id) == expectedEntries.map(\.id))
        #expect(rows[0].entry.hostID == rows[1].entry.hostID)
        #expect(rows[0].entry.kind == rows[1].entry.kind)
    }

    @Test func workspaceHistoryAlignsProtocolWithNameAndTimeWithAddress() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceListView.swift"),
            encoding: .utf8
        )
        let historyRows = try #require(
            source.components(separatedBy: "private var historyRowsContent").last?
                .components(separatedBy: "private func statusTint").first
        )
        let metadataRows = historyRows.components(separatedBy: "HStack(alignment: .center, spacing: 12) {")
        #expect(metadataRows.count == 3)
        #expect(metadataRows[1].contains("Text(row.host.name)"))
        #expect(metadataRows[1].contains("Text(row.entry.kind.label)"))
        #expect(metadataRows[2].contains("Text(app.library.loginAddress(for: row.host))"))
        #expect(metadataRows[2].contains("Text(row.entry.connectedAt, format: .relative"))
    }

    @Test func workspaceHistoryOffersProtocolShortcutsAndDestructiveRemoval() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceList = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceListView.swift"),
            encoding: .utf8
        )
        let historyRows = try #require(
            workspaceList.components(separatedBy: "private var historyRowsContent").last?
                .components(separatedBy: "private func statusTint").first
        )
        #expect(historyRows.contains(".contextMenu {"))
        #expect(historyRows.contains("Button(\"SSH\", systemImage: \"terminal\")"))
        #expect(historyRows.contains("Button(\"SFTP\", systemImage: \"folder\")"))
        #expect(historyRows.contains(".swipeActions(edge: .trailing, allowsFullSwipe: true)"))
        #expect(
            historyRows.components(
                separatedBy: "app.connectionHistory.delete(row.entry.id)"
            ).count == 3
        )

        let toolbar = try String(
            contentsOf: root.appending(path: "TFI/Features/HostChooser/MobileConnectionPicker.swift"),
            encoding: .utf8
        )
        #expect(toolbar.contains("Button(\"Clear History\", systemImage: \"trash\", role: .destructive"))
        let clearHistory = try #require(toolbar.range(of: "Button(\"Clear History\""))
        let closeAll = try #require(toolbar.range(of: "Button(\"Close All Workspaces\""))
        let separator = try #require(
            toolbar.range(
                of: "Divider()",
                range: closeAll.upperBound..<clearHistory.lowerBound
            ))
        #expect(closeAll.lowerBound < separator.lowerBound)
        #expect(separator.lowerBound < clearHistory.lowerBound)
        #expect(!toolbar[closeAll.lowerBound..<separator.lowerBound].contains("role: .destructive"))
        #expect(workspaceList.contains("app.connectionHistory.clearAll()"))
        #expect(workspaceList.contains("\"Clear connection history?\""))
    }

    @Test func sharedHostPickerUsesConfiguredTitleWithoutHostsHeaderOrProtocolControl() async throws {
        let app = try MobileAppModel(inMemory: true)
        app.library.upsert(Host(name: "Production", host: "production.example.invalid"))

        try await withNavigation(
            MobileHostPicker(
                library: app.library,
                title: "Add Server",
                emptyDescription: "Add a saved Linux server to start monitoring.",
                cancel: {},
                select: { _ in }),
            language: "en"
        ) { navigation in
            #expect(navigation.topViewController?.navigationItem.title == "Add Server")
            #expect(descendant(of: UISegmentedControl.self, in: navigation) == nil)
            #expect(!labels(in: navigation.view).contains("Hosts"))
        }

        try await withNavigation(
            MobileConnectionPicker(library: app.library, connect: { _, _ in }, cancel: {}),
            language: "en"
        ) { navigation in
            #expect(descendant(of: UISegmentedControl.self, in: navigation) != nil)
            #expect(!labels(in: navigation.view).contains("Hosts"))
        }
    }

    @Test func snippetHostPickerUsesContextualTitlesAndCheckmarkConfirmation() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Production", host: "production.example.invalid")
        app.library.upsert(host)

        try await withStandaloneNavigation(
            MobileSnippetHostPicker(
                app: app, selected: [], title: "Execute on Hosts", actionTitle: "Execute",
                requiresSelection: true, save: { _ in }),
            language: "en"
        ) { navigation in
            #expect(navigation.topViewController?.navigationItem.title == "Execute on Hosts")
            let execute = try #require(toolbarButton(named: "Execute", in: navigation))
            #expect(!execute.isEnabled)
        }

        try await withStandaloneNavigation(
            MobileSnippetHostPicker(
                app: app, selected: [host.id], title: "Add Hosts", actionTitle: "Done",
                requiresSelection: false, save: { _ in }),
            language: "en"
        ) { navigation in
            #expect(navigation.topViewController?.navigationItem.title == "Add Hosts")
            let done = try #require(toolbarButton(named: "Done", in: navigation))
            #expect(done.isEnabled)
        }
    }

    @Test func snippetHostPickerSharesSingleSelectionRowsAndUsesATintedCheckmark() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedPicker = try String(
            contentsOf: root.appending(path: "TFI/Features/HostChooser/MobileConnectionPicker.swift"),
            encoding: .utf8)
        let snippetPicker = try String(
            contentsOf: root.appending(path: "TFI/Features/Snippets/MobileSnippetsView.swift"),
            encoding: .utf8)

        #expect(sharedPicker.components(separatedBy: "MobileHostPickerRow(").count >= 2)
        #expect(snippetPicker.contains("MobileHostPickerRow("))
        #expect(snippetPicker.contains("Button(actionTitle, systemImage: \"checkmark\")"))
        #expect(snippetPicker.contains(".labelStyle(.iconOnly)"))
        #expect(snippetPicker.contains(".foregroundStyle(.tint)"))
        #expect(snippetPicker.contains(".accessibilityAddTraits(selected.contains(host.id) ? [.isSelected] : [])"))
    }

    @Test(
        arguments: [
            ("en", "Connect", "More"),
            ("zh-Hans", "连接", "更多"),
            ("zh-Hant", "連線", "更多"),
        ])
    func workspaceToolbarExposesLocalizedActions(
        language: String, expectedConnectName: String, expectedMoreName: String
    ) async throws {
        var connectActivations = 0
        try await withNavigation(
            ToolbarHost(
                hasWorkspaces: true,
                closeAll: {},
                connect: { connectActivations += 1 }),
            language: language
        ) { navigation in
            let connect = try #require(toolbarButton(named: expectedConnectName, in: navigation))
            let connectAction = try #require(connect.action)
            #expect(UIApplication.shared.sendAction(connectAction, to: connect.target, from: connect, for: nil))
            #expect(connectActivations == 1)

            let more = try #require(toolbarButton(named: expectedMoreName, in: navigation))
            #expect(more.isEnabled)
        }
    }

    @Test func workspaceToolbarKeepsMoreAndConnectAvailableWithoutWorkspaces() async throws {
        try await withNavigation(
            ToolbarHost(hasWorkspaces: false, closeAll: {}, connect: {}),
            language: "en"
        ) { navigation in
            let more = try #require(toolbarButton(named: "More", in: navigation))
            #expect(more.isEnabled)
            let connect = try #require(toolbarButton(named: "Connect", in: navigation))
            #expect(connect.isEnabled)
        }
    }

    private func withNavigation<Content: View>(
        _ content: Content,
        language: String,
        check: (UINavigationController) throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack { content }.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
        try check(navigation)
    }

    private func withStandaloneNavigation<Content: View>(
        _ content: Content,
        language: String,
        check: (UINavigationController) throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: content.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
        try check(navigation)
    }

    private func toolbarButton(named name: String, in navigation: UINavigationController) -> UIBarButtonItem? {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
            + (item.rightBarButtonItems ?? [])
        return buttons.first { button in
            button.accessibilityLabel == name || button.title == name || button.customView?.accessibilityLabel == name
        }
    }

    private func descendant<T: UIViewController>(of type: T.Type, in controller: UIViewController) -> T? {
        var pending = [controller]
        var visited = Set<ObjectIdentifier>()
        while let next = pending.popLast() {
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            if let result = next as? T { return result }
            pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return nil
    }

    private func descendant<T: UIView>(of type: T.Type, in viewController: UIViewController) -> T? {
        descendant(of: type, in: viewController.view)
    }

    private func descendant<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews {
            if let result = descendant(of: type, in: child) { return result }
        }
        return nil
    }

    private func labels(in view: UIView) -> [String] {
        var result = (view as? UILabel).flatMap(\.text).map { [$0] } ?? []
        for child in view.subviews { result.append(contentsOf: labels(in: child)) }
        return result
    }
}

private struct ToolbarHost: View {
    let hasWorkspaces: Bool
    let closeAll: () -> Void
    let connect: () -> Void

    var body: some View {
        Color.clear
            .navigationTitle("Workspaces")
            .toolbar {
                MobileWorkspaceToolbar(
                    hasWorkspaces: hasWorkspaces,
                    hasHistory: false,
                    closeAll: closeAll,
                    clearHistory: {},
                    connect: connect
                )
            }
    }
}
