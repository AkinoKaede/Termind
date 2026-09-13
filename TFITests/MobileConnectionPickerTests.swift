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
                MobileWorkspaceToolbar(hasWorkspaces: hasWorkspaces, closeAll: closeAll, connect: connect)
            }
    }
}
