import GhosttyTerminal
import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow)
@MainActor
struct MobileTerminalSearchIntegrationTests {
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

    init(kind: ConnectionHistoryEntry.Kind, fullWorkspace: Bool = false) throws {
        app = try MobileAppModel(inMemory: true)
        workspace = MobileWorkspace(
            descriptor: .init(hostID: UUID(), title: "Search", kind: kind), hosts: app.library)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.keyWindow
        window = UIWindow(windowScene: scene)
        if fullWorkspace {
            host = UIHostingController(rootView: WorkspaceSearchFixtureContent(app: app, workspace: workspace))
        } else {
            host = UIHostingController(rootView: SearchFixtureContent(workspace: workspace))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    var searchController: UISearchController? { searchController(in: host) }

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

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
        workspace.disconnect()
    }

    private func searchController(in controller: UIViewController) -> UISearchController? {
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
