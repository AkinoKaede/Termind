import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileAISettingsToolbarTests {
    @Test func workspaceDetailHidesBottomTabsAndRestoresThemOnExit() async throws {
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
                #expect(tabController.isTabBarHidden)
                visibility.showsDetail = false
                try await Task.sleep(for: .milliseconds(300))
                #expect(!tabController.isTabBarHidden)
            }
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
                        library: app.library, commandGenerator: app.commandGenerator,
                        workspace: workspace, workspaces: [workspace.descriptor],
                        selectWorkspace: { _ in }, renameWorkspace: { _ in },
                        canCloseMultipleWorkspaces: false,
                        openSameDirectory: { _ in }, closeWorkspace: { _ in },
                        closeOtherWorkspaces: { _ in })
                } else {
                    Text("Workspaces")
                }
            }
            .tabItem { Label("Workspaces", systemImage: "terminal") }
        }
    }
}
