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
        var selections: [(Host.ID, MobileWorkspaceDescriptor.Kind)] = []
        let model = MobileConnectionPickerModel(library: app.library) { selections.append(($0, $1)) }

        #expect(model.kind == .ssh)
        #expect(model.isLibraryEmpty)

        let production = Host(name: "Production", host: "production.example.invalid")
        let staging = Host(name: "Staging", host: "staging.example.invalid")
        app.library.upsert(production)
        app.library.upsert(staging)

        #expect(!model.isLibraryEmpty)
        #expect(Set(model.hosts.map(\.id)) == Set([production.id, staging.id]))

        model.query = "prod"
        #expect(model.hosts.map(\.id) == [production.id])

        model.select(production)
        #expect(selections.count == 1)
        #expect(selections.first?.0 == production.id)
        #expect(selections.first?.1 == .ssh)

        model.kind = .sftp
        model.select(staging)
        #expect(selections.count == 2)
        #expect(selections.last?.0 == staging.id)
        #expect(selections.last?.1 == .sftp)
    }

    @Test(
        arguments: [
            ("en", "Connect", "More"),
            ("zh-Hans", "连接", "更多"),
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
