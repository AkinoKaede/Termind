import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileWorkspaceMenuTests {
    @Test(arguments: [false, true], [HorizontalEdge?.none, .leading, .trailing])
    func switcherIncludesOpenedAndDormantWorkspaceDescriptorsInOrder(
        isTopBar: Bool, verticalEdge: HorizontalEdge?
    ) async throws {
        let iconSwitcher = isTopBar
        let app = try MobileAppModel(inMemory: true)
        let opened = MobileWorkspaceDescriptor(hostID: UUID(), title: "Opened", kind: .ssh)
        let dormant = MobileWorkspaceDescriptor(hostID: UUID(), title: "Dormant", kind: .sftp)
        let workspace = MobileWorkspace(descriptor: opened, hosts: app.library)
        defer { workspace.disconnect() }

        try await withNavigation(
            MobileWorkspaceView(
                library: app.library, commandGenerator: app.commandGenerator,
                workspace: workspace, workspaces: [opened, dormant],
                unreadWorkspaceIDs: [dormant.id],
                selectWorkspace: { _ in }, renameWorkspace: { _ in }, canCloseMultipleWorkspaces: true,
                openSameDirectory: { _ in }, closeWorkspace: { _ in }, closeOtherWorkspaces: { _ in }
            )
            .environment(\.mobileToolbarLayout, MobileToolbarLayout(isTopBar: isTopBar, verticalEdge: verticalEdge))
        ) { navigation in
            let source =
                iconSwitcher
                ? toolbarButton(named: "Workspaces", in: navigation)?.menu
                : navigation.topViewController?.navigationItem.titleMenuProvider?([])
            let menu = try await resolvedMenu(#require(source), in: navigation.view)
            let actions = menuActions(menu)
            #expect(actions.map(\.title) == ["Opened", "Dormant"])
            #expect(try #require(actions[0].image).isSymbolImage)
            #expect(try #require(actions[1].image).isSymbolImage == false)
        }
    }

    @Test(arguments: [false, true], [HorizontalEdge?.none, .leading, .trailing])
    func assistantSwitcherRemovesTheUnreadIconWhenTheConversationIsRead(
        isTopBar: Bool, verticalEdge: HorizontalEdge?
    ) async throws {
        let iconSwitcher = isTopBar
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "notification-menu")
        await scene.assistant.load()
        let first = ConversationModel()
        first.appendUserTurn("Current conversation")
        let second = ConversationModel()
        second.appendUserTurn("Unread conversation")
        scene.assistant.library.insertAndSelect(second)
        scene.assistant.library.insertAndSelect(first)
        second.markNotificationsUnread()
        try await withNavigation(
            MobileAssistantView(app: app, model: scene.assistant, libraryRoute: .constant(nil))
                .environment(\.mobileToolbarLayout, MobileToolbarLayout(isTopBar: isTopBar, verticalEdge: verticalEdge))
        ) { navigation in
            for unread in [true, false] {
                if !unread { second.markNotificationsRead() }
                try await Task.sleep(for: .milliseconds(350))
                let source =
                    iconSwitcher
                    ? toolbarButton(named: "Conversations", in: navigation)?.menu
                    : navigation.topViewController?.navigationItem.titleMenuProvider?([])
                let menu = try await resolvedMenu(#require(source), in: navigation.view)
                let action = try #require(menuActions(menu).first { $0.title == second.derivedTitle })
                #expect(try #require(action.image).isSymbolImage == !unread)
            }
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
                ? ["Rename", "Close", "Close Others"]
                : ["Rename", "Close"]
            #expect(actions.map(\.title) == expected)
            #expect(!actions[0].attributes.contains(.destructive))
            #expect(actions.dropFirst().allSatisfy { $0.attributes.contains(.destructive) })
            #expect(actions.contains { $0.title == "Close All" } == false)
            if canCloseMultipleWorkspaces {
                let closeOthers = try #require(actions.last)
                #expect(closeOthers.image == UIImage(systemName: "xmark"))
            }
            let separatedActions = menu.children.compactMap { $0 as? UIMenu }
                .filter { $0.options.contains(.displayInline) }
                .map { menuActions($0).map(\.title) }
            #expect(separatedActions == (canCloseMultipleWorkspaces ? [["Close Others"]] : []))
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
        if let window = view.window {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(image, named: "workspace-menu.png")
        }
        interaction.dismissMenu()
        try await Task.sleep(for: .milliseconds(300))
        return try #require(resolvedMenu)
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
