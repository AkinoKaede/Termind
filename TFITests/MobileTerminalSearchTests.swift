// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyTerminal
import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow)
@MainActor
struct MobileTerminalSearchIntegrationTests {
    @Test func expandingVaultAfterWorkspaceSearchKeepsSidebarAvailable() async throws {
        let fixture = try SearchFixture(kind: .ssh, fullRoot: true)
        defer { fixture.close() }
        let scene = try #require(fixture.scene)
        fixture.resize(width: 430, height: 900, sizeClass: .compact)
        try await fixture.settle()
        let tabs = try #require(fixture.tabController)
        let search = try #require(fixture.searchController)
        search.isActive = true
        try await fixture.settle()
        scene.selectedDestination = .vault
        try await fixture.settle()

        fixture.resize(width: 1024, height: 900, sizeClass: .regular)
        if #available(iOS 27.0, *) { tabs.sidebar.preferredPlacement = .sidebar }
        tabs.sidebar.isHidden = false
        try await fixture.settle()
        if #available(iOS 27.0, *) { #expect(tabs.sidebar.isAvailable) }
        #expect(!search.isActive)
        #expect(!tabs.sidebar.isHidden)
        #expect(!tabs.isTabBarHidden)
        #expect(scene.selectedDestination == .vault)

        // The retained workspace must also keep navigation available in sidebar mode.
        scene.selectedDestination = .workspaces
        try await fixture.settle()
        #expect(!tabs.sidebar.isHidden)
        #expect(!tabs.isTabBarHidden)
        scene.selectedDestination = .vault
        try await fixture.settle()
        #expect(!tabs.sidebar.isHidden)
        #expect(!tabs.isTabBarHidden)
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp])
    func leavingWorkspaceSearchRestoresVaultNavigationAcrossResizing(kind: ConnectionHistoryEntry.Kind) async throws {
        let fixture = try SearchFixture(kind: kind, fullRoot: true)
        defer { fixture.close() }
        let scene = try #require(fixture.scene)
        try await fixture.settle()
        let tabs = try #require(fixture.tabController)
        let workspaceSearch = try #require(fixture.searchController)

        for _ in 0..<2 {
            workspaceSearch.isActive = true
            try await fixture.settle()
            workspaceSearch.searchBar.becomeFirstResponder()
            try await fixture.enter("deploy")
            #expect(workspaceSearch.isActive)
            scene.selectedDestination = .vault
            try await fixture.settle()
            #expect(!workspaceSearch.isActive)
            #expect(!fixture.workspace.find.isPresented)
            #expect(!workspaceSearch.searchBar.searchTextField.isFirstResponder)
            // Retained pages still receive model updates while another tab is visible.
            if kind == .sftp {
                fixture.workspace.sftpChannel.query = "deploy updated"
            } else {
                fixture.workspace.find.updateQuery("deploy updated")
            }
            try await fixture.settle()
            #expect(!workspaceSearch.isActive)

            let vaultSearch = try #require(fixture.searchController)
            #expect(vaultSearch !== workspaceSearch)
            vaultSearch.isActive = true
            try await fixture.settle()
            // Vault uses SwiftUI's search delegate, so drive UIKit's dismissal
            // rather than calling the workspace adapter's cancel callback.
            vaultSearch.isActive = false
            try await fixture.settle()
            #expect(!vaultSearch.isActive)
            for (width, height): (CGFloat, CGFloat) in [(900, 600), (600, 900)] {
                fixture.resize(width: width, height: height)
                try await fixture.settle()
                #expect(!tabs.isTabBarHidden)
                #expect(fixture.searchController === vaultSearch)
                #expect(!vaultSearch.isActive)
            }

            scene.selectedDestination = .workspaces
            try await fixture.settle()
            #expect(fixture.searchController === workspaceSearch)
            #expect(!workspaceSearch.isActive)
            #expect(workspaceSearch.searchBar.text == "deploy updated")
        }
    }

    enum Dismissal: CaseIterable {
        case native
        case terminalThenNative
        case programmatic
    }

    @Test(arguments: Dismissal.allCases)
    func closingSearchAllowsRepeatedPresentationWithRetainedQuery(dismissal: Dismissal) async throws {
        let fixture = try SearchFixture(kind: .ssh)
        defer { fixture.close() }
        try await fixture.settle()
        let workspace = fixture.workspace
        workspace.find.updateQuery("deploy")

        for iteration in 0..<3 {
            workspace.find.present()
            try await fixture.settle()
            let search = try #require(fixture.searchController)
            #expect(search.isActive)
            #expect(search.searchBar.searchTextField.isFirstResponder)
            #expect(search.searchBar.text == "deploy")
            if iteration == 1 {
                try await fixture.enter("")
                #expect(workspace.find.query.isEmpty)
                #expect(workspace.find.isPresented)
                try await fixture.enter("deploy")
                #expect(workspace.find.query == "deploy")
            }

            if dismissal == .terminalThenNative {
                workspace.terminal.requestFocus()
                try await fixture.settle()
                #expect(!search.searchBar.searchTextField.isFirstResponder)
            }
            if dismissal == .programmatic {
                workspace.find.dismiss()
            } else if workspace.find.isPresented {
                try fixture.cancelSearch()
            }
            try await fixture.settle()
            #expect(!workspace.find.isPresented)
            #expect(!search.isActive)
            #expect(!search.searchBar.searchTextField.isFirstResponder)
            #expect(workspace.find.query == "deploy")
        }
    }

    @Test(arguments: ["", "deploy", "missing"])
    func reopeningSearchPreservesTerminalSurfaceAndOutput(query: String) async throws {
        let fixture = try SearchFixture(kind: .ssh, fullWorkspace: true)
        defer { fixture.close() }
        try await fixture.settle()
        let workspace = fixture.workspace
        let surface = try #require(workspace.terminal.surface)
        guard case .inMemory(let backend) = workspace.terminal.configuration.backend else {
            Issue.record("Expected an in-memory terminal")
            return
        }
        backend.receive("deploy completed\r\nretained terminal output\r\n$ ")
        backend.waitForPendingOutput()
        try await fixture.settle()
        #expect(workspace.readViewportText()?.contains("retained terminal output") == true)
        let generation = workspace.uploadConnectionGeneration

        for _ in 0..<3 {
            let search = try #require(fixture.searchController)
            search.isActive = true
            try await fixture.settle()
            search.searchBar.becomeFirstResponder()
            try await fixture.settle()
            if workspace.find.query != query { try await fixture.enter(query) }
            workspace.terminal.requestFocus()
            try await fixture.settle()
            search.searchBar.becomeFirstResponder()
            try await fixture.settle()
            #expect(workspace.terminal.surface === surface)
            #expect(workspace.uploadConnectionGeneration == generation)
            #expect(workspace.readViewportText()?.contains("retained terminal output") == true)
            try fixture.cancelSearch()
            try await fixture.settle()
            #expect(workspace.terminal.surface === surface)
            #expect(workspace.readViewportText()?.contains("retained terminal output") == true)
        }
    }

    @Test func sftpSearchCanCloseAndReopenWithTheRetainedFilter() async throws {
        let fixture = try SearchFixture(kind: .sftp)
        defer { fixture.close() }
        try await fixture.settle()

        for iteration in 0..<3 {
            let search = try #require(fixture.searchController)
            search.isActive = true
            try await fixture.settle()
            search.searchBar.becomeFirstResponder()
            try await fixture.settle()
            #expect(search.isActive)
            #expect(search.searchBar.searchTextField.isFirstResponder)
            #expect(search.searchBar.text == (iteration == 0 ? "" : "report"))
            if iteration == 1 {
                try await fixture.enter("")
                #expect(fixture.workspace.sftpChannel.query.isEmpty)
                #expect(search.isActive)
            }
            try await fixture.enter("report")
            #expect(fixture.workspace.sftpChannel.query == "report")
            try fixture.cancelSearch()
            try await fixture.settle()
            #expect(!search.isActive)
            #expect(!search.searchBar.searchTextField.isFirstResponder)
            #expect(fixture.workspace.sftpChannel.query == "report")
        }
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp])
    func connectionJourneyKeepsSearchAndTheTerminalMounted(
        kind: ConnectionHistoryEntry.Kind
    ) async throws {
        let fixture = try SearchFixture(kind: kind)
        defer { fixture.close() }
        try await fixture.settle()
        let terminal = fixture.workspace.terminal.attachedPlatformView
        let search = try #require(fixture.searchController)
        search.isActive = true
        try await fixture.settle()
        search.searchBar.becomeFirstResponder()
        try await fixture.settle()
        try await fixture.enter("deploy")

        let host = Host(name: "Search Journey", host: "journey.invalid")
        fixture.workspace.journey.begin(host: host, route: [host], purpose: .sshSession, username: nil)
        try await fixture.settle()
        #expect(fixture.searchController === search)
        #expect(search.isActive)
        #expect(search.searchBar.text == "deploy")
        try fixture.cancelSearch()
        try await fixture.settle()
        #expect(!search.isActive)

        fixture.workspace.journey.hide()
        try await fixture.settle()
        #expect(fixture.searchController === search)
        #expect(!search.isActive)
        if kind == .ssh {
            #expect(fixture.workspace.terminal.attachedPlatformView === terminal)
            fixture.workspace.find.present()
            try await fixture.settle()
            #expect(search.isActive)
            #expect(search.searchBar.text == "deploy")
        } else {
            #expect(fixture.workspace.sftpChannel.query == "deploy")
        }
    }
}

@MainActor
private final class SearchFixture {
    let app: MobileAppModel
    let workspace: MobileWorkspace
    let window: UIWindow
    let previous: UIWindow?
    let host: UIViewController
    let scene: MobileSceneModel?

    init(kind: ConnectionHistoryEntry.Kind, fullWorkspace: Bool = false, fullRoot: Bool = false) throws {
        app = try MobileAppModel(inMemory: true)
        workspace = MobileWorkspace(
            descriptor: .init(hostID: UUID(), title: "Search", kind: kind), hosts: app.library)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.keyWindow
        window = UIWindow(windowScene: scene)
        if fullRoot {
            let model = MobileSceneModel(app: app, sessionID: "search-navigation-test")
            model.workspaceSession.acceptRecovery(
                .init(workspaces: [workspace], descriptors: [workspace.descriptor], order: [workspace.id]))
            model.selectedDestination = .workspaces
            model.workspaceID = workspace.id
            self.scene = model
            host = UIHostingController(rootView: MobileRootView(app: app, scene: model))
        } else if fullWorkspace {
            self.scene = nil
            host = UIHostingController(rootView: WorkspaceSearchFixtureContent(app: app, workspace: workspace))
        } else {
            self.scene = nil
            host = UIHostingController(rootView: SearchFixtureContent(workspace: workspace))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    var searchController: UISearchController? { searchController(in: host) }

    var tabController: UITabBarController? {
        func find(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: host)
    }

    func enter(_ text: String) async throws {
        let field = try #require(searchController?.searchBar.searchTextField)
        field.text = text
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
    }

    func cancelSearch() throws {
        let search = try #require(searchController)
        let delegate = try #require(search.searchBar.delegate)
        delegate.searchBarCancelButtonClicked?(search.searchBar)
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }

    func resize(width: CGFloat, height: CGFloat, sizeClass: UIUserInterfaceSizeClass? = nil) {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        if let sizeClass { host.traitOverrides.horizontalSizeClass = sizeClass }
        window.frame = frame
        host.view.frame = frame
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
        workspace.disconnect()
    }

    private func searchController(in controller: UIViewController) -> UISearchController? {
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
            return searchController(in: selected)
        }
        if let navigation = controller as? UINavigationController, let top = navigation.topViewController {
            return searchController(in: top)
        }
        if let search = controller.navigationItem.searchController { return search }
        for child in controller.children {
            if let search = searchController(in: child) { return search }
        }
        return nil
    }
}

private struct WorkspaceSearchFixtureContent: View {
    let app: MobileAppModel
    let workspace: MobileWorkspace

    var body: some View {
        NavigationStack {
            MobileWorkspaceView(
                library: app.library, commandGenerator: app.commandGenerator,
                workspace: workspace, workspaces: [workspace.descriptor], selectWorkspace: { _ in },
                renameWorkspace: { _ in }, canCloseMultipleWorkspaces: false,
                openSameDirectory: { _ in }, closeWorkspace: { _ in }, closeOtherWorkspaces: { _ in })
        }
    }
}

private struct SearchFixtureContent: View {
    let workspace: MobileWorkspace

    var body: some View {
        NavigationStack {
            Group {
                if workspace.descriptor.kind == .sftp {
                    Text(workspace.sftpChannel.query)
                } else {
                    TerminalSurfaceView(context: workspace.terminal)
                }
            }
            .overlay {
                if workspace.journey.isPresented { Text("Connecting") }
            }
            .navigationTitle(workspace.descriptor.title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(MobileWorkspaceSearchModifier(workspace: workspace))
        }
    }
}
