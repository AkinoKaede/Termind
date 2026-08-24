import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct WindowStateTests {
    @Test
    func pinnedVaultAndChatPrecedeDynamicWorkspaces() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(tabs: [workspace])

        window.select(index: 0)
        #expect(window.selectedTopLevelTab == .vault)
        window.select(index: 1)
        #expect(window.selectedTopLevelTab == .chat)
        window.select(index: 2)
        #expect(window.selectedTopLevelTab == .workspace(workspace.id))

        window.selectVault()
        window.closeSelected()
        #expect(window.tabs.map(\.id) == [workspace.id])
    }

    @Test
    func chatFeatureOwnsConversationLifecycleOutsideWorkspaces() {
        let window = WindowModel()
        let first = window.openChat()
        let second = window.openChat()

        #expect(window.selectedTopLevelTab == .chat)
        #expect(window.tabs.isEmpty)
        #expect(window.chatLibrary.conversations.map(\.id) == [second.id, first.id])

        window.chatLibrary.delete(second.id)
        #expect(window.chatLibrary.selectedConversationID == first.id)
    }

    @Test
    func vaultRoutesNeverBecomeWorkspaceTabs() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(tabs: [workspace])

        window.openPage(.hosts)
        #expect(window.selectedTopLevelTab == .vault)
        #expect(window.vaultDestination == .hosts)
        #expect(window.tabs.map(\.id) == [workspace.id])

        window.select(workspace.id)
        #expect(window.selectedTopLevelTab == .workspace(workspace.id))
    }

    @Test
    func draggingSelectedWorkspaceDisplaysNeighbourAsMergeTarget() {
        let first = Workspace.sshSession(host: Host(name: "First", host: "first.example"))
        let second = Workspace.sshSession(host: Host(name: "Second", host: "second.example"))
        let window = WindowModel(tabs: [first, second])
        window.select(first.id)

        window.dragging = .workspace(first.id)

        #expect(window.displayedTab?.id == second.id)
        #expect(window.selectedTab?.id == first.id)
    }

    @Test
    func hostEditorIsVaultNavigationAndCloseTabCannotCloseHiddenWork() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(tabs: [workspace])

        window.openHostEditor(host: host)
        #expect(window.selectedTopLevelTab == .vault)
        #expect(window.vaultDestination == .hostEditor(host.id))
        window.closeSelected()
        #expect(window.tabs.map(\.id) == [workspace.id])
    }

    @Test
    func windowsKeepPresentationAndContextPanelStateIsolated() {
        let first = WindowModel(vaultDestination: .hosts)
        let second = WindowModel(vaultDestination: .hosts)
        let host = UUID()

        first.hostChooser = .connect
        first.selectDetail(.host(host), on: .hosts)

        #expect(first.hostChooser == .connect)
        #expect(second.hostChooser == nil)
        #expect(second.detailSelection(for: .hosts).isEmpty)
    }

    @Test
    func windowSheetRouteIsMutuallyExclusive() {
        let state = WindowPresentationState()

        state.hostChooser = .connect
        #expect(state.hostChooser == .connect)
        state.hostChooser = .batchStartup
        #expect(state.hostChooser == .batchStartup)
        state.hostChooser = nil
        #expect(state.sheet == nil)
    }

    @Test
    func contextPanelOverrideExpiresWhenFocusLeavesItsPane() {
        let firstHost = Host(name: "First", host: "first.example")
        let secondHost = Host(name: "Second", host: "second.example")
        let first = Workspace.sshSession(host: firstHost)
        let second = Workspace.sshSession(host: secondHost)
        let window = WindowModel(tabs: [first, second])
        window.selectedTabID = first.id

        window.contextPanel.show(.snippet(UUID()), scopedTo: first.focusedPane)
        #expect(window.activeDetailSelection.first?.kind == ContextPanelDetailID.Kind.snippet)

        window.selectedTabID = second.id
        window.contextPanel.focusedPaneDidChange(to: second.focusedPane)
        #expect(window.activeDetailSelection == [.host(secondHost.id)])
    }

    @Test
    func featureRoutesReplaceRatherThanStack() {
        let hosts = HostsPageState()
        let group = HostGroup(name: "Production", parentID: nil)
        hosts.sheet = .newGroup
        hosts.sheet = .editGroup(group)
        guard case .editGroup(let routedGroup) = hosts.sheet else {
            Issue.record("Expected one active host sheet route")
            return
        }
        #expect(routedGroup.id == group.id)

        let snippets = SnippetsPageState()
        let batch = SnippetBatch(snippets: [])
        snippets.confirmation = .executeDestructive(batch)
        snippets.confirmation = .deleteSnippets(batch)
        guard case .deleteSnippets = snippets.confirmation else {
            Issue.record("Expected one active snippet confirmation route")
            return
        }
    }

    @Test
    func sessionsMixSSHAndSFTPInTabAndPaneOrder() {
        let firstHost = Host(name: "First", host: "first.example")
        let secondHost = Host(name: "Second", host: "second.example")
        let mixed = Workspace.sshSession(host: firstHost)
        let sshPane = mixed.focusedPane
        mixed.splitFocusedPane(axis: .horizontal, with: .sftpSession(host: firstHost))
        let sftpPane = mixed.focusedPane
        let secondSSH = Workspace.sshSession(host: secondHost)
        let window = WindowModel(tabs: [mixed, secondSSH])

        #expect(window.sessionPanes.map(\.pane.id) == [sshPane.id, sftpPane.id, secondSSH.focusedPane.id])
        #expect(window.sshSessionPanes.map(\.pane.id) == [sshPane.id, secondSSH.focusedPane.id])
        #expect(window.sftpSessionPanes.map(\.pane.id) == [sftpPane.id])
        #expect(window.sessionPanes.map(\.pane.symbol) == ["apple.terminal", "folder", "apple.terminal"])
    }

    @Test
    func sftpTitlesUseHostNameWithoutPrefixAndFallBackToSFTP() {
        let host = Host(name: "Uploads", host: "uploads.example")
        let store = HostStore(hosts: [host])
        let pane = Pane.sftpSession(host: host)
        let missing = Pane(.sftpSession(SFTPSessionModel(hostID: UUID(), initialPath: "/")))

        #expect(pane.title(in: store) == "Uploads")
        #expect(pane.sidebarTitle(in: store) == "Uploads")
        #expect(missing.title(in: store) == "SFTP")
        #expect(missing.sidebarTitle(in: store) == "SFTP")
    }

    @Test
    func selectingAndClosingUnifiedSessionPanesKeepsWorkspaceStateConsistent() {
        let host = Host(name: "Host", host: "host.example")
        let workspace = Workspace.sshSession(host: host)
        let sshPane = workspace.focusedPane
        workspace.splitFocusedPane(axis: .horizontal, with: .sftpSession(host: host))
        let sftpPane = workspace.focusedPane
        let window = WindowModel(tabs: [workspace])

        workspace.focus(sshPane.id)
        window.select(workspace.id)

        workspace.focus(sftpPane.id)

        window.closePane(sftpPane.id)
        #expect(window.sessionPanes.map(\.pane.id) == [sshPane.id])
        #expect(workspace.focusedPaneID == sshPane.id)

        window.closePane(sshPane.id)
        #expect(window.sessionPanes.isEmpty)
        #expect(window.tabs.isEmpty)
    }

    @Test
    func appRoutesHostsToSSHAndSFTPSessionsForTabsAndWorkspaces() {
        let first = Host(name: "First", host: "first.example")
        let second = Host(name: "Second", host: "second.example")
        let store = HostStore(hosts: [first, second])
        let app = AppModel(hosts: store)
        let window = WindowModel()

        let sshTab = app.open(first, as: .sshSession, in: window)
        let sftpTab = app.open(second, as: .sftpSession, in: window)
        #expect(sshTab.focusedPane.kind == .sshSession)
        #expect(sftpTab.focusedPane.kind == .sftpSession)

        app.open([first, second], as: .sshSession, layout: .separateTabs, in: window)
        #expect(window.selectedTabID == window.tabs[2].id)
        #expect(window.tabs.suffix(2).map(\.focusedPane.kind) == [.sshSession, .sshSession])

        app.open([first, second], as: .sftpSession, layout: .oneWorkspace, in: window)
        #expect(window.selectedTab?.panes.map(\.kind) == [.sftpSession, .sftpSession])
    }

    @Test
    func reopeningAClosedTerminalCreatesAFreshConnectingSession() throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let pane = workspace.focusedPane
        pane.customTitle = "Logs"
        let closedSession = try #require(pane.sshSession)
        let window = WindowModel(tabs: [workspace])

        window.close(workspace.id)
        #expect(closedSession.status == .disconnected)
        #expect(window.canReopen)

        window.reopenLastClosed()

        let reopenedPane = try #require(window.selectedTab?.focusedPane)
        let reopenedSession = try #require(reopenedPane.sshSession)
        #expect(reopenedSession !== closedSession)
        #expect(reopenedSession.hostID == host.id)
        #expect(reopenedSession.status == .connecting)
        #expect(reopenedPane.customTitle == "Logs")
        #expect(window.selectedTab === workspace)
        #expect(!window.canReopen)
    }

    @Test
    func terminalPathOpensSFTPInANewTabOrTheCurrentWorkspace() {
        var host = Host(name: "Files", host: "files.example")
        host.sftpSessionInitialPath = "/configured"
        let sshWorkspace = Workspace.sshSession(host: host)
        let window = WindowModel(tabs: [sshWorkspace])

        let newTab = window.openSFTPSession(
            host: host, initialPath: "/var/log/", placement: .newTab
        )

        #expect(window.tabs.count == 2)
        #expect(window.selectedTab === newTab)
        #expect(newTab.focusedPane.sftpSession?.path == "/var/log")
        #expect(newTab.focusedPane.sftpSession?.initialPath == "/var/log")
        #expect(host.sftpSessionInitialPath == "/configured")

        window.select(sshWorkspace.id)
        let result = window.openSFTPSession(
            host: host, initialPath: "/srv/app", placement: .currentWorkspace
        )

        #expect(result === sshWorkspace)
        #expect(window.tabs.count == 2)
        #expect(sshWorkspace.panes.map(\.kind) == [.sshSession, .sftpSession])
        #expect(sshWorkspace.focusedPane.sftpSession?.path == "/srv/app")
    }

    @Test
    func sftpWithoutAnOverrideKeepsTheHostsConfiguredInitialPath() {
        var host = Host(name: "Files", host: "files.example")
        host.sftpSessionInitialPath = "/configured"
        let window = WindowModel()

        let workspace = window.openSFTPSession(host: host)

        #expect(workspace.focusedPane.sftpSession?.path == "/configured")
        #expect(workspace.focusedPane.sftpSession?.initialPath == "/configured")
    }

    @Test
    func duplicateDestinationsPreservePaneAndWorkspaceScope() {
        let host = Host(name: "Host", host: "host.example")
        let original = Workspace.sshSession(host: host)
        let window = WindowModel(tabs: [original])

        window.duplicateSelected(axis: .horizontal)
        #expect(window.tabs.count == 1)
        #expect(original.panes.count == 2)

        let focusedPane = original.focusedPane
        window.duplicatePaneInNewTab()
        #expect(window.tabs.count == 2)
        #expect(window.selectedTab?.panes.count == 1)
        #expect(window.selectedTab?.focusedPane.kind == focusedPane.kind)

        window.select(original.id)
        window.duplicateSelectedInNewTab()
        #expect(window.tabs.count == 3)
        #expect(window.selectedTab?.panes.count == 2)
        #expect(window.selectedTab?.panes.map(\.kind) == original.panes.map(\.kind))
    }

    @Test
    func normalRemoteExitClosesOnlyItsSplitPane() {
        let firstHost = Host(name: "First", host: "first.example")
        let secondHost = Host(name: "Second", host: "second.example")
        let workspace = Workspace.sshSession(host: firstHost)
        let firstPane = workspace.focusedPane
        let firstSSHSession = firstPane.sshSession!
        workspace.splitFocusedPane(axis: .horizontal, with: .sshSession(host: secondHost))
        let secondPane = workspace.focusedPane
        workspace.focus(firstPane.id)
        workspace.broadcastsInput = true
        let window = WindowModel(tabs: [workspace])

        firstSSHSession.handleRemoteExit(.success(0))

        #expect(window.tabs.count == 1)
        #expect(workspace.panes.map(\.id) == [secondPane.id])
        #expect(workspace.layout.pane(firstPane.id) == nil)
        #expect(workspace.focusedPaneID == secondPane.id)
        #expect(!workspace.broadcastsInput)
        #expect(firstSSHSession.inputRouter == nil)
    }

    @Test
    func normalRemoteExitClosesLastPaneAndSelectsNeighboringTab() {
        let host = Host(name: "Host", host: "host.example")
        let sshSessionTab = Workspace.sshSession(host: host)
        let sshSession = sshSessionTab.focusedPane.sshSession!
        let neighbor = Workspace.sftpSession(host: host)
        let window = WindowModel(tabs: [sshSessionTab, neighbor])
        window.select(sshSessionTab.id)

        sshSession.handleRemoteExit(.success(0))

        #expect(window.tabs.map(\.id) == [neighbor.id])
        #expect(window.selectedTabID == neighbor.id)
    }

    @Test
    func transportFailureKeepsPaneOpenForReconnect() {
        let host = Host(name: "Host", host: "host.example")
        let workspace = Workspace.sshSession(host: host)
        let sshSession = workspace.focusedPane.sshSession!
        let window = WindowModel(tabs: [workspace])

        sshSession.handleRemoteExit(.failure(.disconnected))

        #expect(window.tabs.map(\.id) == [workspace.id])
        #expect(workspace.focusedPane.sshSession === sshSession)
        guard case .failed = sshSession.status else {
            Issue.record("Expected transport failure to remain visible")
            return
        }
    }
}
