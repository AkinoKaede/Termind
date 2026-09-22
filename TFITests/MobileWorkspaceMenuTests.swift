import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileWorkspaceMenuTests {
    @Test func switcherIncludesOpenedAndDormantWorkspaceDescriptorsInOrder() async throws {
        let app = try MobileAppModel(inMemory: true)
        let opened = MobileWorkspaceDescriptor(hostID: UUID(), title: "Opened", kind: .ssh)
        let dormant = MobileWorkspaceDescriptor(hostID: UUID(), title: "Dormant", kind: .sftp)
        let workspace = MobileWorkspace(descriptor: opened, hosts: app.library)
        defer { workspace.disconnect() }

        try await withNavigation(
            MobileWorkspaceView(
                library: app.library, pro: app.pro, commandGenerator: app.commandGenerator,
                workspace: workspace, workspaces: [opened, dormant],
                selectWorkspace: { _ in }, renameWorkspace: { _ in }, canCloseMultipleWorkspaces: true,
                openSameDirectory: { _ in }, closeWorkspace: { _ in }, closeOtherWorkspaces: { _ in }
            )
            .environment(\.mobileToolbarLayout, MobileToolbarLayout(isTopBar: true))
        ) { navigation in
            let button = try #require(toolbarButton(named: "Workspaces", in: navigation))
            let menu = try await resolvedMenu(#require(button.menu), in: navigation.view)
            let actions = menuActions(menu)
            #expect(actions.map(\.title) == ["Opened", "Dormant"])
        }
    }

    @Test(arguments: [false, true])
    func lifecycleActionsOnlyShowBatchClosingWhenMultipleWorkspacesCanClose(
        canCloseMultipleWorkspaces: Bool
    ) async throws {
        try await withNavigation(
            LifecycleMenuHost(canCloseMultipleWorkspaces: canCloseMultipleWorkspaces)
        ) { navigation in
            let button = try #require(toolbarButton(named: "Workspace Actions", in: navigation))
            let menu = try await resolvedMenu(#require(button.menu), in: navigation.view)
            let actions = menuActions(menu)
            let expected =
                canCloseMultipleWorkspaces
                ? ["Rename", "Close", "Close Other Workspaces"]
                : ["Rename", "Close"]
            #expect(actions.map(\.title) == expected)
            #expect(!actions[0].attributes.contains(.destructive))
            #expect(actions.dropFirst().allSatisfy { $0.attributes.contains(.destructive) })
            #expect(actions.contains { $0.title == "Close All Workspaces" } == false)
            if canCloseMultipleWorkspaces {
                let closeOthers = try #require(actions.last)
                #expect(closeOthers.image == UIImage(systemName: "xmark"))
            }
            let separatedActions = menu.children.compactMap { $0 as? UIMenu }
                .filter { $0.options.contains(.displayInline) }
                .map { menuActions($0).map(\.title) }
            #expect(separatedActions == (canCloseMultipleWorkspaces ? [["Close Other Workspaces"]] : []))
        }
    }

    private func withNavigation<Content: View>(
        _ content: Content,
        check: (UINavigationController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { content })
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
        try await check(navigation)
    }

    private func resolvedMenu(_ menu: UIMenu, in view: UIView) async throws -> UIMenu {
        let button = UIButton(frame: CGRect(x: 100, y: 100, width: 44, height: 44))
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        view.addSubview(button)
        defer { button.removeFromSuperview() }
        button.performPrimaryAction()
        try await Task.sleep(for: .milliseconds(500))
        let interaction = try #require(button.contextMenuInteraction)
        var resolvedMenu: UIMenu?
        interaction.updateVisibleMenu { resolved in
            resolvedMenu = resolved
            return resolved
        }
        interaction.dismissMenu()
        try await Task.sleep(for: .milliseconds(300))
        return try #require(resolvedMenu)
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return menuActions(submenu) }
            return []
        }
    }

    private func toolbarButton(named name: String, in navigation: UINavigationController) -> UIBarButtonItem? {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
            + (item.rightBarButtonItems ?? [])
        return buttons.first {
            $0.accessibilityLabel == name || $0.title == name || $0.customView?.accessibilityLabel == name
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

private struct LifecycleMenuHost: View {
    let canCloseMultipleWorkspaces: Bool

    var body: some View {
        Color.clear
            .navigationTitle("Workspace")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        MobileWorkspaceLifecycleMenuActions(
                            canCloseMultipleWorkspaces: canCloseMultipleWorkspaces,
                            rename: {}, close: {}, closeOthers: {})
                    } label: {
                        Label("Workspace Actions", systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                    .menuOrder(.fixed)
                }
            }
    }
}
