import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

/// The window has one Find field, and which of six things it points at is
/// decided by the content in front. These pin that mapping down, because the
/// bug it replaces — ⌘F meaning something different depending on where the
/// caret happened to be — is invisible until you are in the wrong buffer.
@Suite
@MainActor
struct WindowToolbarFindTests {
    // `TermindDomain.Host` qualified because Foundation still exports its own `Host`
    // on macOS, which makes the bare name ambiguous in a type position.
    private func host(_ name: String = "web-01") -> TermindDomain.Host {
        TermindDomain.Host(name: name, host: "\(name).example")
    }

    @Test
    func themeSearchUsesToolbarAndPreservesEachAppearanceQuery() throws {
        let window = WindowModel()
        window.openSettings(route: .terminalThemes(.light))
        #expect(window.findKind == .terminalThemes)
        let light = try #require(window.findContext())
        light.query.wrappedValue = "Day"
        window.focusToolbarFind()
        #expect(window.isToolbarFindFocused)

        window.openSettings(route: .terminalThemes(.dark))
        let dark = try #require(window.findContext())
        #expect(dark.query.wrappedValue.isEmpty)
        dark.query.wrappedValue = "Night"
        window.openSettings(route: .terminalCustomThemes)
        let custom = try #require(window.findContext())
        custom.query.wrappedValue = "Personal"
        window.openSettings(route: .terminalCustomTheme(UUID()))
        #expect(window.findContext() == nil)
        window.navigateBackInSettings()
        #expect(window.findContext()?.query.wrappedValue == "Personal")
        window.openSettings(route: .terminalThemes(.dark))
        #expect(window.findContext()?.query.wrappedValue == "Night")
        window.openSettings(route: .terminalThemes(.light))
        #expect(window.findContext()?.query.wrappedValue == "Day")
        window.openSettings(route: .category(.terminal))
        #expect(window.findKind == nil)
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
        #expect(window.canFindInMainContent)
        #expect(window.creationActions.isEmpty)
    }

    /// Welcome participates in the window-level Find command without growing a
    /// second search field in the titlebar.
    @Test
    func focusingFindOnWelcomeRequestsItsContentSearchField() {
        let window = WindowModel()
        var titlebarFocusRequests = 0
        window.focusToolbarFindField = { titlebarFocusRequests += 1 }
        window.openPage(.welcome)

        window.focusToolbarFind()

        #expect(window.welcomeSearchFocusRequest == 1)
        #expect(window.findFocusRequest == 0)
        #expect(!window.isToolbarFindFocused)
        #expect(titlebarFocusRequests == 0)
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
        let browser = Pane.sftpChannel(host: host("files"))
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
        #expect(!window.canFindInMainContent)
        #expect(window.creationActions.isEmpty)
    }

    /// ⌘F on a terminal has to start Ghostty searching as well as focusing the
    /// field, or the first keystroke would filter nothing.
    @Test
    func focusingFindStartsTheTerminalSearch() async {
        let window = WindowModel(workspaces: [Workspace.sshSession(host: host())])
        var directFocusRequests = 0
        window.focusToolbarFindField = { directFocusRequests += 1 }

        window.focusToolbarFind()
        await Task.yield()

        #expect(window.focusedSSHSession?.find.isPresented == true)
        #expect(window.findFocusRequest == 1)
        #expect(window.isToolbarFindFocused)
        #expect(directFocusRequests == 1)
    }

    /// Nothing to find in means the key falls through rather than bumping a
    /// counter nobody is watching.
    @Test
    func focusingFindIsANoOpWhereThereIsNoField() {
        let window = WindowModel(workspaces: [Workspace(pane: Pane(.empty))])

        window.focusToolbarFind()

        #expect(window.findFocusRequest == 0)
        #expect(window.welcomeSearchFocusRequest == 0)
    }

    @Test
    func creationActionsFollowTheContentInFrontNotTheSidebar() {
        let window = WindowModel()

        window.openPage(.hosts)
        #expect(window.creationActions.map(\.id) == ["host", "group", "ssh-folder"])

        // Switching the sidebar to the Assistant must not put New Chat in the
        // titlebar while Hosts is still the page being looked at.
        window.sidebarMode = .assistant
        #expect(window.creationActions.map(\.id) == ["host", "group", "ssh-folder"])

        window.openPage(.keychain)
        #expect(window.creationActions.map(\.id) == ["import", "generate", "identity", "ssh-folder"])
        #expect(window.creationActions.map(\.startsGroup) == [false, false, true, true])

        window.openPage(.snippets)
        #expect(window.creationActions.map(\.id) == ["snippet", "package"])
    }

    @Test
    func sshFolderImportIsLastAndStartsASeparateMenuGroup() {
        let window = WindowModel()
        for page in [VaultPage.hosts, .keychain, .knownHosts] {
            let actions = window.creationActions(for: page)
            #expect(actions.last?.id == "ssh-folder")
            #expect(actions.last?.startsGroup == true)
            let menu = window.creationMenu(for: page, locale: Locale(identifier: "en"))
            #expect(menu[menu.count - 2].isSeparator)
        }
    }

    @Test
    func keychainIdentityAndFolderImportStartSeparateMenuGroups() {
        let window = WindowModel()
        let menu = window.creationMenu(for: .keychain, locale: Locale(identifier: "en"))

        #expect(menu.count == 6)
        #expect(menu[2].isSeparator)
        #expect(menu[4].isSeparator)
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

    /// Each provider answers only for its own destination, so the catalog can
    /// gain one without the others — or the window — being told.
    @Test
    func aTitleProviderDeclinesDestinationsThatAreNotItsOwn() {
        let window = WindowModel()
        window.selectAssistant()

        let locale = Locale(identifier: "zh-Hans")
        #expect(VaultWindowTitleProvider().title(in: window, locale: locale) == nil)
        #expect(AssistantWindowTitleProvider().title(in: window, locale: locale) != nil)
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
        let locale = Locale(identifier: "zh-Hans")

        window.selectAssistant()
        #expect(title.title(in: window, locale: locale) == AppLocalization.string("New Chat", locale: locale))

        window.selectAssistant(conversation.id)
        #expect(title.title(in: window, locale: locale) == "Nginx rollout")

        window.showAssistantArchive()
        #expect(title.title(in: window, locale: locale) == AppLocalization.string("Archived", locale: locale))
    }

    @Test
    func workspaceTitleLocalizesOnlyBuiltInFallbacks() {
        let store = HostLibraryModel()
        let locale = Locale(identifier: "zh-Hans")
        let first = Pane(.empty)
        let second = Pane(.empty)
        let workspace = Workspace(pane: first)
        workspace.layout = .split(
            .init(
                axis: .horizontal, fraction: 0.5,
                first: .leaf(first), second: .leaf(second)
            )
        )

        #expect(workspace.title(in: store, locale: locale) == AppLocalization.string("Workspace", locale: locale))
        workspace.customTitle = "Production"
        #expect(workspace.title(in: store, locale: locale) == "Production")
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
