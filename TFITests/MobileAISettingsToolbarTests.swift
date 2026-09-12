import AgentKit
import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAISettingsToolbarTests {
    @Test func managementPagesExposeTheirNativeToolbarActions() async throws {
        let app = try MobileAppModel(inMemory: true)

        try await withNavigation(MobileModelsSettingsView(ai: app.ai)) { names in
            #expect(names.contains("Add Provider"))
        }
        try await withNavigation(MobileSkillSettings(skills: app.skills)) { names in
            #expect(names.contains("Add Skill"))
            #expect(names.contains("More"))
            #expect(!names.contains("Import Skill…"))
        }
        try await withNavigation(MobileMCPSettings(ai: app.ai, pro: app.pro)) { names in
            #expect(names.contains("Add Server"))
        }
    }

    @Test func mcpServerUsesPushedEditorToolbar() async throws {
        let app = try MobileAppModel(inMemory: true)
        let server = MCPServer(name: "Test", url: "https://example.invalid/mcp")

        try await withNavigation(MobileMCPEditor(ai: app.ai, pro: app.pro, server: server)) { names in
            #expect(names.contains("More"))
            #expect(names.contains("Save"))
            #expect(!names.contains("Cancel"))
        }
    }

    @Test func workspacePagesExposeTheirExpectedToolbarActions() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)

        for kind in [ConnectionHistoryEntry.Kind.ssh, .sftp] {
            let workspace = MobileWorkspace(
                descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: kind),
                hosts: app.library)
            try await withNavigation(
                MobileWorkspaceView(
                    library: app.library, pro: app.pro, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: [workspace],
                    selectWorkspace: { _ in }, renameWorkspace: { _ in },
                    openSameDirectory: { _ in }, closeWorkspace: { _ in })
            ) { names in
                #expect(names.contains("More"))
                #expect(!names.contains("History"))
                #expect(!names.contains("Transfers"))
                #expect(!names.contains("Close"))
                #expect(names.contains("Previous Location") == (kind == .sftp))
                #expect(names.contains("Next Location") == (kind == .sftp))
            }
        }
    }

    @Test func workspaceDetailHidesTheRootTabBar() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)

        for kind in [ConnectionHistoryEntry.Kind.ssh, .sftp] {
            let workspace = MobileWorkspace(
                descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: kind),
                hosts: app.library)
            let visibility = WorkspaceTabBarVisibility()
            let content = WorkspaceTabBarHarness(app: app, workspace: workspace, visibility: visibility)
            try await withHostedView(content) { controller in
                let tabController = try #require(descendant(of: UITabBarController.self, in: controller))
                #expect(tabController.tabBar.isHidden)
                visibility.showsDetail = false
                try await Task.sleep(for: .milliseconds(300))
                #expect(!tabController.tabBar.isHidden)
            }
        }
    }

    private func withNavigation<Content: View>(
        _ content: Content,
        check: (Set<String>) throws -> Void
    ) async throws {
        try await withHostedView(NavigationStack { content }) { controller in
            let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
            try check(Set(toolbarNames(in: navigation.topViewController?.navigationItem)))
        }
    }

    private func withHostedView<Content: View>(
        _ content: Content,
        check: (UIViewController) async throws -> Void
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

    private func toolbarNames(in item: UINavigationItem?) -> [String] {
        guard let item else { return [] }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
            + (item.rightBarButtonItems ?? [])
        return buttons.compactMap { button in
            button.accessibilityLabel ?? button.title ?? button.customView?.accessibilityLabel
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

@MainActor
private final class WorkspaceTabBarVisibility: ObservableObject {
    @Published var showsDetail = true
}

private struct WorkspaceTabBarHarness: View {
    let app: MobileAppModel
    let workspace: MobileWorkspace
    @ObservedObject var visibility: WorkspaceTabBarVisibility

    var body: some View {
        TabView {
            NavigationStack {
                if visibility.showsDetail {
                    MobileWorkspaceView(
                        library: app.library, pro: app.pro, commandGenerator: app.commandGenerator,
                        workspace: workspace, workspaces: [workspace],
                        selectWorkspace: { _ in }, renameWorkspace: { _ in },
                        openSameDirectory: { _ in }, closeWorkspace: { _ in })
                } else {
                    Text("Workspaces")
                }
            }
            .tabItem { Label("Workspaces", systemImage: "terminal") }
        }
    }
}
