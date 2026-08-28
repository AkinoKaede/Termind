import Foundation
import Testing

@testable import Termind

/// The window has one Find field, and which of six things it points at is
/// decided by the content in front. These pin that mapping down, because the
/// bug it replaces — ⌘F meaning something different depending on where the
/// caret happened to be — is invisible until you are in the wrong buffer.
@Suite
@MainActor
struct WindowToolbarFindTests {
    // `Termind.Host` qualified because Foundation still exports its own `Host`
    // on macOS, which makes the bare name ambiguous in a type position.
    private func host(_ name: String = "web-01") -> Termind.Host {
        Termind.Host(name: name, host: "\(name).example")
    }

    @Test
    func vaultPagesEachResolveToTheirOwnFind() {
        let window = WindowModel()

        window.openPage(.hosts)
        #expect(window.findKind == .hosts)

        window.openPage(.keychain)
        #expect(window.findKind == .keychain)

        window.openPage(.snippets)
        #expect(window.findKind == .snippets)
    }

    /// Welcome searches hosts with its own large field, which is the page's
    /// whole point. A second one in the titlebar would be two fields for one job.
    @Test
    func welcomeOffersNoTitlebarFind() {
        let window = WindowModel()
        window.openPage(.welcome)

        #expect(window.findKind == nil)
        #expect(!window.canFindInMainContent)
        #expect(window.creationActions.isEmpty)
    }

    @Test
    func assistantResolvesToConversationSearch() {
        let window = WindowModel()
        window.selectAssistant()

        #expect(window.findKind == .assistant)
        #expect(window.creationActions.map(\.id) == ["chat"])
    }

    @Test
    func workspaceResolvesToTheFocusedPaneRatherThanAnyPane() throws {
        let workspace = Workspace.sshSession(host: host())
        let window = WindowModel(workspaces: [workspace])
        #expect(window.findKind == .terminal)

        // Split a file browser in beside the shell and focus it. "Any session in
        // the workspace" would still answer `.terminal` here.
        let browser = Pane.sftpSession(host: host("files"))
        workspace.splitFocusedPane(axis: .horizontal, with: browser)
        workspace.focus(browser.id)
        #expect(window.findKind == .sftp)

        let shell = try #require(workspace.panes.first { $0.sshSession != nil })
        workspace.focus(shell.id)
        #expect(window.findKind == .terminal)
    }

    @Test
    func anEmptyWorkspaceHasNothingToFindIn() {
        let window = WindowModel(workspaces: [Workspace(pane: Pane(.empty))])

        #expect(window.findKind == nil)
        #expect(window.creationActions.isEmpty)
    }

    /// ⌘F on a terminal has to start Ghostty searching as well as focusing the
    /// field, or the first keystroke would filter nothing.
    @Test
    func focusingFindStartsTheTerminalSearch() {
        let window = WindowModel(workspaces: [Workspace.sshSession(host: host())])

        window.focusToolbarFind()

        #expect(window.focusedSSHSession?.find.isPresented == true)
        #expect(window.findFocusRequest == 1)
    }

    /// Nothing to find in means the key falls through rather than bumping a
    /// counter nobody is watching.
    @Test
    func focusingFindIsANoOpWhereThereIsNoField() {
        let window = WindowModel()
        window.openPage(.welcome)

        window.focusToolbarFind()

        #expect(window.findFocusRequest == 0)
    }

    @Test
    func creationActionsFollowTheContentInFrontNotTheSidebar() {
        let window = WindowModel()

        window.openPage(.hosts)
        #expect(window.creationActions.map(\.id) == ["host", "group"])

        // Switching the sidebar to the Assistant must not put New Chat in the
        // titlebar while Hosts is still the page being looked at.
        window.sidebarMode = .assistant
        #expect(window.creationActions.map(\.id) == ["host", "group"])

        window.openPage(.keychain)
        #expect(window.creationActions.map(\.id) == ["import", "generate", "identity"])

        window.openPage(.snippets)
        #expect(window.creationActions.map(\.id) == ["snippet", "package"])
    }

    /// Each Vault page keeps its own query, and keeps it across a page switch —
    /// the field lives in the titlebar and outlives the page under it.
    @Test
    func eachPageQueryIsSeparateAndSurvivesSwitchingPages() {
        let window = WindowModel()

        window.vaultPages.hosts.query = "edge"
        window.vaultPages.keychain.query = "deploy"
        window.vaultPages.snippets.query = "restart"

        window.openPage(.keychain)
        window.openPage(.hosts)

        #expect(window.vaultPages.query(for: .hosts) == "edge")
        #expect(window.vaultPages.query(for: .keychain) == "deploy")
        #expect(window.vaultPages.query(for: .snippets) == "restart")
    }

    @Test
    func titlebarNamesTheContentInFront() {
        let window = WindowModel()
        let title = VaultWindowTitleProvider()

        // Welcome is the app's front door, so it is named after the app.
        window.openPage(.welcome)
        #expect(title.title(in: window) == ApplicationIdentity.displayName)

        window.openPage(.hosts)
        #expect(title.title(in: window) == VaultPage.hosts.title)

        window.openPage(.keychain)
        #expect(title.title(in: window) == VaultPage.keychain.title)

        window.openPage(.snippets)
        #expect(title.title(in: window) == VaultPage.snippets.title)
    }

    /// Each provider answers only for its own destination, so the catalog can
    /// gain one without the others — or the window — being told.
    @Test
    func aTitleProviderDeclinesDestinationsThatAreNotItsOwn() {
        let window = WindowModel()
        window.selectAssistant()

        #expect(VaultWindowTitleProvider().title(in: window) == nil)
        #expect(AssistantWindowTitleProvider().title(in: window) != nil)
    }

    /// The Assistant names the conversation, not the destination.
    @Test
    func assistantTitleFollowsTheConversation() {
        let store = AssistantConversationStore()
        let conversation = ConversationModel()
        conversation.customTitle = "Nginx rollout"
        store.insert(conversation)
        let window = WindowModel(assistantLibrary: AssistantLibraryModel(store: store))
        let title = AssistantWindowTitleProvider()

        window.selectAssistant()
        #expect(title.title(in: window) == String(localized: "New Chat"))

        window.selectAssistant(conversation.id)
        #expect(title.title(in: window) == "Nginx rollout")

        window.showAssistantArchive()
        #expect(title.title(in: window) == String(localized: "Archived"))
    }

    /// A tag stops existing when its last host loses it, so a filter pinned to
    /// it has to go too — otherwise the page sits empty with no way back.
    @Test
    func tagFilterDropsTagsNoHostCarriesAnyMore() {
        let state = HostsPageState()
        state.selectedTags = ["prod", "edge"]

        state.pruneSelectedTags(against: ["prod", "staging"])

        #expect(state.selectedTags == ["prod"])
    }
}
