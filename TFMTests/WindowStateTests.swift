import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct WindowStateTests {
    @Test func showHistoryLeavesLivePanesRunningAndAlwaysShowsConnections() throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        session.status = .connected
        let window = WindowModel(workspaces: [workspace])
        window.showsSidebar = false
        window.showConnectionHistory()
        window.showConnectionHistory()
        #expect(window.selectedDestination == .vault)
        #expect(window.showsSidebar && window.sidebarMode == .history)
        #expect(window.workspaces.first === workspace)
        #expect(session.status == .connected)
    }

    @Test func recentClosedReopensASpecificPaneWithoutConsumingTheNewestItem() throws {
        let first = Workspace(pane: Pane(.empty))
        let second = Workspace(pane: Pane(.empty))
        let window = WindowModel(workspaces: [first, second])
        window.close(first.id)
        window.close(second.id)
        #expect(window.recentlyClosedWorkspaces.map(\.id) == [second.id, first.id])
        window.reopenClosedWorkspace(first.id)
        #expect(window.selectedWorkspace === first)
        #expect(window.recentlyClosedWorkspaces.map(\.id) == [second.id])
        window.reopenClosedWorkspace(first.id)
        #expect(window.workspaces.count == 1)
        window.reopenLastClosed()
        #expect(window.selectedWorkspace === second)
        #expect(!window.canReopen)
    }

    @Test(arguments: [WindowDestination.vault, .metrics, .settings, .assistant])
    func showAssistantWorksOutsideWorkspacesWithoutReplacingItsNavigation(_ destination: WindowDestination) {
        let window = WindowModel()
        window.showAssistantArchive()
        window.selectedDestination = destination
        window.showsSidebar = false

        window.showAssistant()
        window.showAssistant()

        #expect(window.selectedDestination == .assistant)
        #expect(window.showsSidebar)
        #expect(window.sidebarMode == .assistant)
        #expect(window.isAssistantArchivePresented)
        #expect(window.assistantLibrary.conversations.isEmpty)
    }

    @Test func showAssistantKeepsTheCurrentWorkspaceAndConversation() {
        let window = WindowModel()
        let conversation = window.assistantLibrary.createConversation()
        let workspace = Workspace(pane: Pane(.empty))
        window.open(workspace)
        window.openAssistantInSidebar(conversation.id)
        window.showsSidebar = false
        window.sidebarMode = .navigation

        window.showAssistant()
        window.showAssistant()

        #expect(window.selectedWorkspace === workspace)
        #expect(window.showsSidebar && window.sidebarMode == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)
    }

    @Test
    func sshAndTelnetPanesUseDistinctProtocolSymbols() {
        let host = Host(
            name: "Console", host: "console.example.invalid",
            telnetEnabled: true)

        #expect(Pane.sshSession(host: host).symbol == MenuSymbol.ssh)
        #expect(Pane.telnetSession(host: host).symbol == MenuSymbol.telnet)
        #expect(MenuSymbol.ssh != MenuSymbol.telnet)
    }

    @Test
    func assistantManualOrderMovesAcrossPinnedBoundaryAndStaysStableAfterActivity() throws {
        let first = ConversationModel(updatedAt: Date(timeIntervalSinceReferenceDate: 10))
        let second = ConversationModel(updatedAt: Date(timeIntervalSinceReferenceDate: 20))
        let pinned = ConversationModel(updatedAt: Date(timeIntervalSinceReferenceDate: 30))
        pinned.isPinned = true
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [first, second, pinned]
            ))

        let updates = try #require(
            library.orderUpdates(
                moving: first.id, toPinned: true, before: pinned.id
            ))
        library.applyOrder(updates)

        #expect(library.pinnedConversations.map(\.id) == [first.id, pinned.id])
        #expect(library.activeConversations.map(\.id) == [second.id])
        first.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        #expect(library.pinnedConversations.map(\.id) == [first.id, pinned.id])
    }

    @Test
    func newWindowStartsOnWelcome() {
        let window = WindowModel()

        #expect(window.selectedDestination == .vault)
        #expect(window.vaultDestination == .welcome)
    }

    @Test
    func numericWorkspaceSelectionExcludesVaultAndChats() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace])

        window.select(index: 0)
        #expect(window.selectedDestination == .workspace(workspace.id))
        window.selectVault()
        window.select(index: 1)
        #expect(window.selectedDestination == .vault)

        window.selectVault()
        window.closeSelected()
        #expect(window.workspaces.map(\.id) == [workspace.id])
    }

    @Test
    func closingTheLastWorkspaceKeepsTheGlobalSidebarMode() {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let window = WindowModel(workspaces: [workspace])
        window.sidebarMode = .history

        window.close(workspace.id)
        window.reconcileSidebarMode()

        #expect(window.workspaces.isEmpty)
        #expect(window.selectedDestination == .vault)
        #expect(window.sidebarMode == .history)
    }

    @Test(arguments: [false, true])
    func closingWorkspacesPromotesTheVisibleSidebarConversationFullScreen(closeAll: Bool) {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(workspaces: [workspace], assistantLibrary: library)
        window.sidebarMode = .assistant
        window.openAssistantInSidebar(conversation.id)

        if closeAll {
            window.closeAll()
        } else {
            window.close(workspace.id)
        }

        #expect(window.workspaces.isEmpty)
        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)
        #expect(window.sidebarMode == .assistant)
    }

    @Test
    func closingTheLastWorkspacePromotesTheVisibleSidebarArchiveFullScreen() {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let window = WindowModel(workspaces: [workspace])
        window.sidebarMode = .assistant
        window.showAssistantArchiveInSidebar()

        window.close(workspace.id)

        #expect(window.workspaces.isEmpty)
        #expect(window.selectedDestination == .assistant)
        #expect(window.isAssistantArchivePresented)
        #expect(window.assistantLibrary.selectedConversation == nil)
    }

    @Test
    func assistantFeatureOwnsConversationLifecycleOutsideWorkspaces() {
        let window = WindowModel()
        let first = window.assistantLibrary.createConversation()
        let second = window.assistantLibrary.createConversation()
        window.selectAssistant(second.id)

        #expect(window.selectedDestination == .assistant)
        #expect(window.workspaces.isEmpty)
        #expect(window.assistantLibrary.conversations.map(\.id) == [second.id, first.id])

        window.assistantLibrary.delete(second.id)
        #expect(window.assistantLibrary.selectedConversationID == first.id)
    }

    @Test
    func assistantLibrarySeparatesPinnedActiveAndArchivedByRecentActivity() {
        let old = ConversationModel(updatedAt: Date(timeIntervalSince1970: 1))
        let recent = ConversationModel(updatedAt: Date(timeIntervalSince1970: 3))
        let pinned = ConversationModel(updatedAt: Date(timeIntervalSince1970: 2))
        pinned.isPinned = true
        let archived = ConversationModel(updatedAt: Date(timeIntervalSince1970: 4))
        archived.archivedAt = .now
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [old, recent, pinned, archived]
            ))

        #expect(library.pinnedConversations.map(\.id) == [pinned.id])
        #expect(library.activeConversations.map(\.id) == [recent.id, old.id])
        #expect(library.archivedConversations.map(\.id) == [archived.id])
    }

    @Test
    func archivingClearsPinAndUnarchivingReturnsTheConversationToChats() {
        let conversation = ConversationModel()
        conversation.isPinned = true
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)

        window.setAssistantArchived(conversation.id, archived: true)
        #expect(conversation.isArchived)
        #expect(!conversation.isPinned)
        #expect(library.archivedConversations.map(\.id) == [conversation.id])

        window.setAssistantArchived(conversation.id, archived: false)
        #expect(!conversation.isArchived)
        #expect(library.activeConversations.map(\.id) == [conversation.id])
    }

    @Test
    func archivingTheOpenConversationReturnsMainAndSidebarSurfacesToNewChat() {
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)
        window.selectAssistant(conversation.id)
        window.openAssistantInSidebar(conversation.id)

        window.setAssistantArchived(conversation.id, archived: true)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(window.sidebarAssistantConversation == nil)
        #expect(!window.isAssistantArchivePresented)
    }

    @Test
    func archiveIsASeparateWindowDestinationAndConversationNavigationLeavesIt() {
        let conversation = ConversationModel()
        conversation.archivedAt = .now
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)

        window.showAssistantArchive()
        #expect(window.isAssistantArchivePresented)
        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation == nil)

        window.selectAssistant(conversation.id)
        #expect(!window.isAssistantArchivePresented)
        #expect(window.assistantLibrary.selectedConversation === conversation)

        window.showAssistantArchiveInSidebar()
        #expect(window.isAssistantArchivePresented)
        #expect(window.sidebarAssistantConversation == nil)

        window.openAssistantInSidebar(conversation.id)
        #expect(!window.isAssistantArchivePresented)
        #expect(window.sidebarAssistantConversation === conversation)
    }

    @Test
    func openingConversationFullScreenKeepsAssistantSidebarSelected() {
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)

        window.openAssistantFullScreen(conversation.id)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)
        #expect(window.sidebarMode == .assistant)
        #expect(window.sidebarAssistantConversation === conversation)
    }

    @Test
    func openingRecentHostKeepsTheGlobalHistoryMode() {
        let host = Host(name: "Recent", host: "recent.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let window = WindowModel()
        window.sidebarMode = .history

        let workspace = app.open(host, as: .sshSession, in: window)

        #expect(window.selectedDestination == .workspace(workspace.id))
        #expect(window.sidebarMode == .history)

        window.selectVault()
        window.select(workspace.id)
        #expect(window.sidebarMode == .history)
    }

    @Test
    func forkTitlesUseTheLowestFreeWorkspaceStyleNumber() {
        let source = ConversationModel()
        source.customTitle = "Question"
        let store = AssistantConversationStore(conversations: [source])

        #expect(store.nextForkTitle(for: source) == "Question (1)")

        let firstFork = ConversationModel()
        firstFork.customTitle = "Question (1)"
        store.insert(firstFork)
        #expect(store.nextForkTitle(for: source) == "Question (2)")
        #expect(store.nextForkTitle(for: firstFork) == "Question (2)")

        store.remove(firstFork.id)
        #expect(store.nextForkTitle(for: source) == "Question (1)")
    }

    @Test(arguments: [AgentRunState.idle, .running, .waitingForApproval], [false, true])
    func failedMetadataSaveKeepsConversationStateAndReportsTheError(
        state: AgentRunState, compacting: Bool
    ) async {
        let repository = FailingConversationOperationRepository()
        let hosts = HostLibraryModel()
        let dependencies = AppDependencies(
            hostRepository: InMemoryHostRepository(), outboxRunner: nil,
            agentRunRepository: repository
        )
        let app = AppModel(hosts: hosts, dependencies: dependencies)
        let window = WindowModel()
        app.registerWindow(window)
        let conversation = window.assistantLibrary.createConversation()
        conversation.handle(.runState(state))
        if compacting { conversation.beginCompaction() }

        window.toggleAssistantPin(conversation.id)
        for _ in 0..<100 {
            if window.assistantOperationError != nil { break }
            await Task.yield()
        }

        #expect(!conversation.isPinned)
        #expect(window.assistantOperationError == "Storage unavailable")
        #expect(conversation.runState == state)
        #expect(conversation.isCompacting == compacting)
    }

    @Test
    func failedCompactionSaveDoesNotChangeTheInMemoryContext() async throws {
        let repository = FailingConversationOperationRepository()
        let hosts = HostLibraryModel()
        let app = AppModel(
            hosts: hosts,
            dependencies: AppDependencies(
                hostRepository: InMemoryHostRepository(), outboxRunner: nil,
                agentRunRepository: repository
            )
        )
        let conversation = ConversationModel()
        // Both turns are sized in tokens, because that is the unit the cut is
        // chosen in. A last turn worth less than `keepRecentTokens` never
        // satisfies the budget, so the search walks past it to the start of the
        // transcript and `compactionSpan` returns nil with nothing to compact.
        let keepRecentTokens = 2
        conversation.appendUserTurn("old " + filler(tokens: 1_000))
        conversation.appendUserTurn("recent " + filler(tokens: keepRecentTokens))
        let span = try #require(
            conversation.compactionSpan(keepRecentTokens: keepRecentTokens)
        )
        let record = try #require(
            conversation.prepareCompaction(
                summary: "summary", cut: span.cut
            ))
        let transcript = conversation.transcript
        let estimate = conversation.contextEstimate

        await #expect(throws: (any Error).self) {
            try await app.persistAndApplyCompaction(record, to: conversation, cut: span.cut)
        }

        #expect(conversation.transcript == transcript)
        #expect(conversation.contextEstimate == estimate)
        #expect(conversation.compactions.isEmpty)
    }

    /// Each window used to build its own `ConversationModel` for the same
    /// conversation id, so a reply streaming in one window was invisible in the
    /// other and both could start a run against the same stored history.
    @Test
    func twoWindowsShareOneInstanceOfEachConversationButNotTheSelection() {
        let shared = AssistantConversationStore()
        let first = WindowModel()
        let second = WindowModel()
        first.assistantLibrary.adopt(shared)
        second.assistantLibrary.adopt(shared)

        let conversation = first.assistantLibrary.createConversation()
        let other = first.assistantLibrary.createConversation()

        #expect(second.assistantLibrary.conversations.map(\.id) == [other.id, conversation.id])
        #expect(second.assistantLibrary.conversation(id: conversation.id) === conversation)

        second.selectAssistant(conversation.id)
        #expect(second.assistantLibrary.selectedConversationID == conversation.id)
        #expect(first.assistantLibrary.selectedConversationID == other.id)

        // A delete in one window empties the other's stale selection too.
        first.assistantLibrary.delete(conversation.id)
        second.assistantLibrary.delete(conversation.id)
        #expect(second.assistantLibrary.conversations.map(\.id) == [other.id])
        #expect(second.assistantLibrary.selectedConversationID == other.id)
    }

    @Test
    func aWindowThatAdoptsTheStoreLateKeepsWhatItAlreadyHad() {
        let window = WindowModel()
        let early = window.assistantLibrary.createConversation()

        let shared = AssistantConversationStore()
        window.assistantLibrary.adopt(shared)

        #expect(shared.conversations.map(\.id) == [early.id])
        #expect(window.assistantLibrary.selectedConversationID == early.id)
    }

    @Test
    func selectingAssistantDoesNotCreateAConversation() {
        let window = WindowModel()

        window.activateSidebarMode(.assistant)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.conversations.isEmpty)
        #expect(window.assistantLibrary.selectedConversation == nil)
    }

    @Test
    func assistantAndNavigatorModeRailRoundTripsToThePreviousVaultRoute() {
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)
        window.selectAssistant(conversation.id)
        window.openVaultWork(.hostEditor(nil), on: .hosts)

        // The Assistant mode can already be selected after navigation elsewhere;
        // pressing its selected button must still activate the Assistant route.
        window.sidebarMode = .assistant
        window.activateSidebarMode(.assistant)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)

        window.activateSidebarMode(.navigation)

        #expect(window.selectedDestination == .vault)
        #expect(window.vaultDestination == .hosts)
        #expect(window.vaultWorkRoute == .hostEditor(nil))
    }

    @Test
    func assistantModeRailStaysCompactInWorkspaceAndNavigatorReturnsThereFromFullScreen() {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let window = WindowModel(workspaces: [workspace])

        window.activateSidebarMode(.assistant)

        #expect(window.sidebarMode == .assistant)
        #expect(window.selectedDestination == .workspace(workspace.id))

        let conversation = window.assistantLibrary.createConversation()
        window.openAssistantFullScreen(conversation.id)
        window.activateSidebarMode(.navigation)

        #expect(window.sidebarMode == .navigation)
        #expect(window.selectedDestination == .workspace(workspace.id))
        #expect(window.sidebarAssistantConversation === conversation)
    }

    @Test
    func navigatorFallsBackToVaultWhenTheAssistantReturnWorkspaceWasClosed() {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let window = WindowModel(workspaces: [workspace])
        window.openAssistantFullScreen()

        window.close(workspace.id)
        window.activateSidebarMode(.navigation)

        #expect(window.workspaces.isEmpty)
        #expect(window.selectedDestination == .vault)
    }

    @Test
    func nonNavigationToolModesAndDirectModeAssignmentDoNotNavigate() {
        let window = WindowModel()
        window.openPage(.hosts)

        window.sidebarMode = .assistant
        #expect(window.selectedDestination == .vault)

        window.activateSidebarMode(.snippets)
        #expect(window.selectedDestination == .vault)

        window.activateSidebarMode(.history)
        #expect(window.selectedDestination == .vault)
    }

    @Test
    func enteringAssistantKeepsTheVolatileConversationSelection() {
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)

        window.selectAssistant(conversation.id)
        window.selectVault()
        window.activateSidebarMode(.assistant)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)

        let draft = window.openNewAssistantChat()
        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(draft === window.assistantLibrary.draftConversation)

        window.selectVault()
        window.activateSidebarMode(.assistant)
        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(draft === window.assistantLibrary.draftConversation)
    }

    @Test
    func enteringAssistantKeepsTheVolatileArchiveDestination() {
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(
                conversations: [conversation]
            ))
        let window = WindowModel(assistantLibrary: library)

        window.selectAssistant(conversation.id)
        window.showAssistantArchive()
        window.selectVault()
        window.activateSidebarMode(.assistant)

        #expect(window.isAssistantArchivePresented)
        #expect(window.assistantLibrary.selectedConversation == nil)
    }

    @Test
    func assistantStartsOnNewChatWhenNoVolatileSelectionExists() {
        let previousID = UUID()
        let library = AssistantLibraryModel()
        library.restore([
            StoredAgentConversation(
                id: previousID,
                messages: [AgentTranscriptMessage(role: .user, text: "Previous question")],
                lastRunState: .completed
            )
        ])
        let window = WindowModel(assistantLibrary: library)

        window.selectAssistant()

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(window.assistantLibrary.draftConversation.isEmpty)
        #expect(window.assistantLibrary.conversations.map(\.id) == [previousID])
    }

    @Test
    func newChatJoinsHistoryOnlyAfterItsFirstSend() async {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        let draft = window.openNewAssistantChat()

        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(window.assistantLibrary.conversations.isEmpty)

        draft.composer.draft = "Hello from a new chat"
        let started = app.sendNewAgentDraft(in: window.assistantLibrary)

        #expect(started === draft)
        #expect(window.assistantLibrary.selectedConversation === draft)
        #expect(window.assistantLibrary.conversations.map(\.id) == [draft.id])
        #expect(window.assistantLibrary.draftConversation !== draft)
        await started?.stopAndWait()
    }

    @Test
    func sidebarDraftCreatesConversationOnlyOnFirstValidSend() async {
        let app = AppModel(hosts: HostLibraryModel())
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let window = WindowModel(workspaces: [workspace])

        #expect(app.sendNewAgentConversation(window.sidebar.assistantDraft, in: window.assistantLibrary) == nil)
        #expect(window.assistantLibrary.conversations.isEmpty)

        window.sidebar.assistantDraft.composer.draft = "  Explain this failure.  "
        let conversation = app.sendNewAgentConversation(
            window.sidebar.assistantDraft, in: window.assistantLibrary, context: window.sidebar.sessionContext)
        if let conversation { window.assistantSidebarConversationDidStart(conversation) }

        #expect(conversation?.messages.map(\.text) == ["Explain this failure."])
        #expect(window.assistantLibrary.conversations.count == 1)
        #expect(window.assistantLibrary.conversations.first?.id == conversation?.id)
        #expect(window.sidebarAssistantConversation?.id == conversation?.id)
        #expect(window.selectedDestination == .workspace(workspace.id))
        #expect(window.sidebar.assistantDraft.isEmpty)
        await conversation?.stopAndWait()
    }

    @Test
    func sidebarConversationNavigationSharesSelectionAndDeletionReturnsHome() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let conversation = ConversationModel()
        conversation.composer.draft = "Hello"
        let library = AssistantLibraryModel()
        conversation.sendDraft()
        library.insertAndSelect(conversation)
        let window = WindowModel(workspaces: [workspace], assistantLibrary: library)

        window.openAssistantInSidebar(conversation.id)
        #expect(window.sidebarAssistantConversation?.id == conversation.id)
        #expect(window.assistantLibrary.selectedConversation === conversation)
        #expect(window.selectedDestination == .workspace(workspace.id))

        window.closeAssistantInSidebar()
        #expect(window.sidebarAssistantConversation == nil)
        #expect(window.assistantLibrary.selectedConversation == nil)

        window.openAssistantInSidebar(conversation.id)
        window.deleteAssistantConversation(conversation.id)
        #expect(window.sidebarAssistantConversation == nil)
        #expect(window.assistantLibrary.conversations.isEmpty)
    }

    @Test
    func assistantSidebarShowsFocusedWorkspaceContext() {
        let host = Host(name: "Files", host: "files.example")
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/srv/app")
        workspace.focusedPane.sftpChannel?.homeResolution = .unavailable
        let window = WindowModel(workspaces: [workspace])

        window.hostStore = HostLibraryModel(hosts: [host])

        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host, .directory])
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/srv/app"])
        // The id the host tools require, taken from the focused pane rather than
        // left for the model to guess from the name.
        #expect(window.sidebar.sessionContext.hostID == workspace.focusedPane.hostID)
        #expect(window.sidebar.sessionContext.hostID == host.id)
        #expect(window.sidebar.sessionContext.paneID == nil)
    }

    @Test
    func terminalContextFollowsPaneFocusWithoutConfusingHostAndPaneIDs() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let first = workspace.focusedPane
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])

        let submitted = window.sidebar.sessionContext
        #expect(submitted.paneID == first.id)
        #expect(submitted.hostID == host.id)
        workspace.splitFocusedPane(axis: .horizontal, with: .sshSession(host: host))
        #expect(window.sidebar.sessionContext.paneID == workspace.focusedPane.id)
        #expect(window.sidebar.sessionContext.paneID != submitted.paneID)
        #expect(window.sidebar.sessionContext.hostID == submitted.hostID)
        #expect(submitted.modelContext?.contains("pane_id: \(first.id.uuidString)") == true)

        workspace.splitFocusedPane(axis: .horizontal, with: .sftpChannel(host: host))
        #expect(window.sidebar.sessionContext.paneID == nil)
        workspace.focus(first.id)
        #expect(window.sidebar.sessionContext.paneID == first.id)
        window.selectAssistant()
        window.refreshSessionContext()
        #expect(window.sidebar.sessionContext == .none)
    }

    @Test
    func focusedSFTPPathChangesUpdateSessionContext() {
        let host = Host(name: "Files", host: "files.example")
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/srv")
        let sftpChannel = workspace.focusedPane.sftpChannel!
        sftpChannel.homeResolution = .unavailable
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])

        sftpChannel.navigate(to: "/srv/releases")

        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host, .directory])
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/srv/releases"])

        sftpChannel.goBack()
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/srv"])
    }

    @Test
    func backgroundSFTPPathDoesNotReplaceFocusedPaneContext() {
        let host = Host(name: "Files", host: "files.example")
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/focused")
        let focusedPane = workspace.focusedPane
        focusedPane.sftpChannel?.homeResolution = .unavailable
        workspace.splitFocusedPane(
            axis: .horizontal,
            with: .sftpChannel(host: host, initialPath: "/background")
        )
        let backgroundSession = workspace.focusedPane.sftpChannel!
        workspace.focus(focusedPane.id)
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])

        backgroundSession.navigate(to: "/background/changed")

        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/focused"])
    }

    /// The reported leak: session context must belong to the sidebar, so a
    /// conversation promoted out of it arrives in the Assistant destination carrying
    /// nothing about a host it can no longer see.
    @Test
    func sendingFromTheSidebarDoesNotAttachSessionContextToTheConversation() async {
        let app = AppModel(hosts: HostLibraryModel())
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/srv/app")
        workspace.focusedPane.sftpChannel?.homeResolution = .unavailable
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])
        window.sidebar.assistantDraft.composer.draft = "Why is this slow?"

        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Server", "/srv/app"])

        let conversation = app.sendNewAgentConversation(
            window.sidebar.assistantDraft, in: window.assistantLibrary, context: window.sidebar.sessionContext)
        if let conversation { window.assistantSidebarConversationDidStart(conversation) }

        #expect(conversation?.composer.attachments.isEmpty == true)
        #expect(conversation?.transcript.first?.contextSnapshot?.sessionContext?.contains("/srv/app") == true)
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Server", "/srv/app"])
        await conversation?.stopAndWait()
    }

    /// Leaving every Workspace used to freeze the last host and directory on
    /// screen, because the refresh returned early instead of clearing.
    @Test
    func leavingEveryWorkspaceClearsSessionContext() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/srv/app")
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])

        #expect(!window.sidebar.sessionContext.isEmpty)

        window.selectVault()
        window.refreshSessionContext()

        #expect(window.sidebar.sessionContext == .none)
    }

    /// The Ask Assistant path attaches the failure log, promotes the draft, and
    /// the log goes with the message it belongs to rather than sitting in the
    /// draft as text the user could half-delete.
    @Test
    func promotingASidebarDraftSendsItsAttachmentWithTheFirstTurn() async {
        let app = AppModel(hosts: HostLibraryModel())
        let conversation = ConversationModel()
        conversation.attach(
            ContextChip(kind: .output, label: "Connection error", content: "ssh: refused")
        )
        conversation.composer.draft = "Explain this"

        #expect(app.sendNewAgentConversation(conversation, in: AssistantLibraryModel()) === conversation)

        #expect(conversation.messages.first?.text == "Explain this")
        #expect(conversation.transcript.first?.text.contains("ssh: refused") == true)
        #expect(conversation.composer.attachments.isEmpty, "the attachment went with the turn")
        #expect(conversation.transcript.first?.contextSnapshot != nil)
        await conversation.stopAndWait()
    }

    @Test
    func sshFailureAssistantDraftKeepsTheExistingPromptAndLastFourThousandLogCharacters() throws {
        let conversation = ConversationModel()
        let retainedLog = String(repeating: "x", count: 3_995) + "-tail"
        let log = "discarded-prefix" + retainedLog
        let message = "Connection refused"

        SSHFailureAssistantDraft.populate(
            conversation, message: message, log: log
        )

        let attachment = try #require(conversation.composer.attachments.first)
        #expect(conversation.composer.attachments.count == 1)
        #expect(attachment.kind == .output)
        #expect(attachment.label == String(localized: "Connection Log"))
        #expect(attachment.content == retainedLog)
        #expect(attachment.content.count == 4_000)
        #expect(
            conversation.composer.draft
                == String(localized: "SSH connection failed: \(message). What should I check?")
        )
    }

    /// Opening a conversation in the sidebar used to stamp the focused pane's
    /// host onto it, which is how that host followed the conversation into the
    /// Assistant destination.
    @Test
    func openingASidebarConversationLeavesItUnmarkedByTheFocusedPane() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let conversation = ConversationModel()
        conversation.composer.draft = "Explain this"
        let library = AssistantLibraryModel()
        conversation.sendDraft()
        library.insertAndSelect(conversation)
        conversation.attach(
            ContextChip(kind: .output, label: "Connection error", content: "ssh: refused")
        )
        let window = WindowModel(workspaces: [workspace], assistantLibrary: library)
        window.hostStore = HostLibraryModel(hosts: [host])

        window.openAssistantInSidebar(conversation.id)

        #expect(conversation.composer.attachments.map(\.label) == ["Connection error"])
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Server"])
    }

    @Test
    func focusedSSHSystemInfoUpdatesSessionContextAndSFTPClearsIt() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let sshPane = workspace.focusedPane
        let sshSession = sshPane.sshSession!
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])
        let info = RemoteSystemInfo(
            distributionID: "ubuntu", distributionVersion: "24.04",
            kernelName: "Linux", kernelRelease: "6.8.0", architecture: "x86_64"
        )

        sshSession.receiveShellIntegrationEvent(
            .available(shell: "bash", systemInfo: info, homeDirectory: "/home/test")
        )

        #expect(window.sidebar.sessionContext.systemInfo == info)
        // OS facts reach the model but are not a pill: they are disclosed by the
        // Shell Integration setting, not by the composer.
        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host])

        workspace.splitFocusedPane(axis: .horizontal, with: .sftpChannel(host: host))
        #expect(window.sidebar.sessionContext.systemInfo == nil)

        workspace.focus(sshPane.id)
        #expect(window.sidebar.sessionContext.systemInfo == info)

        sshSession.receiveShellIntegrationEvent(
            .available(shell: "bash", systemInfo: info, homeDirectory: "/home/test")
        )
        sshSession.disconnect()
        #expect(window.sidebar.sessionContext.systemInfo == nil)
    }

    @Test
    func vaultRoutesNeverBecomeWorkspaceTabs() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace])

        window.openPage(.hosts)
        #expect(window.selectedDestination == .vault)
        #expect(window.vaultDestination == .hosts)
        #expect(window.workspaces.map(\.id) == [workspace.id])

        window.select(workspace.id)
        #expect(window.selectedDestination == .workspace(workspace.id))
    }

    @Test(arguments: [true, false])
    func draggingAWorkspacePreservesSelectionAndTemporarilyDisplaysItsMergeTarget(dragSelected: Bool) {
        let first = Workspace.sshSession(host: Host(name: "First", host: "first.example"))
        let second = Workspace.sshSession(host: Host(name: "Second", host: "second.example"))
        let window = WindowModel(workspaces: [first, second])
        window.select(first.id)

        window.dragging = .workspace(dragSelected ? first.id : second.id)

        #expect(window.displayedWorkspace?.id == (dragSelected ? second.id : first.id))
        #expect(window.selectedWorkspace?.id == first.id)
        #expect(window.selectedWorkspaceID == first.id)

        window.dragging = nil

        #expect(window.displayedWorkspace?.id == first.id)
        #expect(window.selectedWorkspaceID == first.id)
    }

    @Test
    func draggingSelectedWorkspaceWithoutMergeNeighbourKeepsItsSelectionDisplayed() {
        let workspace = Workspace.sshSession(host: Host(name: "Only", host: "only.example"))
        let window = WindowModel(workspaces: [workspace])
        window.select(workspace.id)

        window.dragging = .workspace(workspace.id)

        #expect(window.displayedWorkspace?.id == workspace.id)
        #expect(window.selectedWorkspaceID == workspace.id)
    }

    @Test
    func droppingNestedPaneOnNavigatorDetachesItIntoSelectedWorkspace() throws {
        let workspace = Workspace.sshSession(
            host: Host(name: "First", host: "first.example")
        )
        let firstPane = workspace.focusedPane
        workspace.splitFocusedPane(
            axis: .horizontal,
            with: .sshSession(host: Host(name: "Second", host: "second.example"))
        )
        let detachedPane = workspace.focusedPane
        workspace.splitFocusedPane(
            axis: .vertical,
            with: .sshSession(host: Host(name: "Third", host: "third.example"))
        )
        let thirdPane = workspace.focusedPane
        let window = WindowModel(workspaces: [workspace])

        let detachedWorkspace = try #require(window.detachPane(detachedPane.id, at: 0))

        #expect(window.workspaces.map(\.id) == [detachedWorkspace.id, workspace.id])
        #expect(detachedWorkspace.panes.map(\.id) == [detachedPane.id])
        #expect(workspace.panes.map(\.id) == [firstPane.id, thirdPane.id])
        #expect(window.selectedWorkspace === detachedWorkspace)
    }

    /// The inverse of a merge, in one move. Merging is a single gesture, so
    /// undoing it must be too — and the last pane cannot be dragged out at all,
    /// because a pane alone in its Workspace has nothing to detach from.
    @Test
    func separatingPanesUndoesAMergeKeepingLayoutOrder() throws {
        let workspace = Workspace.sshSession(
            host: Host(name: "First", host: "first.example")
        )
        let first = workspace.focusedPane
        workspace.splitFocusedPane(
            axis: .horizontal,
            with: .sshSession(host: Host(name: "Second", host: "second.example"))
        )
        let second = workspace.focusedPane
        workspace.splitFocusedPane(
            axis: .vertical,
            with: .sshSession(host: Host(name: "Third", host: "third.example"))
        )
        let third = workspace.focusedPane
        let neighbour = Workspace.sshSession(
            host: Host(name: "Other", host: "other.example")
        )
        let window = WindowModel(workspaces: [workspace, neighbour])
        let laidOut = workspace.panes.map(\.id)

        window.separatePanes(in: workspace.id)

        // One Workspace per pane, in the order the panes were laid out, all
        // before the Workspace that already followed them.
        #expect(window.workspaces.count == 4)
        #expect(window.workspaces.flatMap { $0.panes.map(\.id) } == laidOut + [neighbour.panes[0].id])
        #expect(window.workspaces.allSatisfy { $0.panes.count == 1 })

        // The row that was right-clicked is still there, and still selected.
        #expect(window.workspaces.first?.id == workspace.id)
        #expect(window.selectedWorkspaceID == workspace.id)
        #expect(Set([first.id, second.id, third.id]) == Set(laidOut))
    }

    /// Nothing to take apart is not an error, and must not reorder anything.
    @Test
    func separatingPanesLeavesASingleePaneWorkspaceAlone() {
        let workspace = Workspace.sshSession(host: Host(name: "Only", host: "only.example"))
        let window = WindowModel(workspaces: [workspace])

        window.separatePanes(in: workspace.id)

        #expect(window.workspaces.map(\.id) == [workspace.id])
        #expect(workspace.panes.count == 1)
    }

    @Test
    func hostEditorIsVaultNavigationAndCloseWorkspaceCannotCloseHiddenWork() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace])

        window.openHostEditor(host: host)
        #expect(window.selectedDestination == .vault)
        #expect(window.vaultDestination == .hosts)
        #expect(window.vaultWorkRoute == .hostEditor(host.id))
        window.closeSelected()
        #expect(window.workspaces.map(\.id) == [workspace.id])
    }

    @Test
    func newHostEditorCarriesOnlyCreationGroupContext() {
        let window = WindowModel()
        let groupID = UUID()

        window.openHostEditor(host: nil, groupID: groupID)
        #expect(window.vaultWorkRoute == .hostEditor(nil, groupID: groupID))

        let host = Host(name: "Server", host: "server.example", groupID: UUID())
        window.openHostEditor(host: host, groupID: groupID)
        #expect(window.vaultWorkRoute == .hostEditor(host.id, groupID: nil))
    }

    @Test(arguments: [false, true])
    func tailscaleDetailsFollowEligibleHostsAndCloseForAnOrdinaryHost(_ isManaged: Bool) {
        let first = Host(name: "First", host: "first.example")
        var second = Host(name: "Second", host: "second.example")
        if isManaged {
            second.tailscale = TailscaleHostReference(groupID: UUID(), stableNodeID: "second")
        }
        let window = WindowModel()
        window.openVaultWork(.tailscaleDetails(first.id), on: .hosts)

        window.updateTailscaleDetails(for: second, hasPeer: !isManaged)
        #expect(window.vaultWorkRoute == .tailscaleDetails(second.id))

        window.updateTailscaleDetails(for: first, hasPeer: false)
        #expect(window.vaultWorkRoute == nil)
        #expect(window.vaultDestination == .hosts)

        window.updateTailscaleDetails(for: second, hasPeer: true)
        #expect(window.vaultWorkRoute == nil)
    }

    @Test
    func clearingTailscaleSelectionClosesDetailsWithoutAffectingOtherEditors() {
        let host = Host(name: "Server", host: "server.example")
        let window = WindowModel()
        window.openVaultWork(.tailscaleDetails(host.id), on: .hosts)

        window.updateTailscaleDetails(for: nil, hasPeer: false)
        #expect(window.vaultWorkRoute == nil)

        window.openHostEditor(host: host)
        window.updateTailscaleDetails(for: nil, hasPeer: false)
        #expect(window.vaultWorkRoute == .hostEditor(host.id))
    }

    @Test
    func deletingTheDisplayedTailscaleHostClosesDetails() {
        let host = Host(name: "Server", host: "server.example")
        let window = WindowModel()
        window.openVaultWork(.tailscaleDetails(host.id), on: .hosts)

        window.closeWorkspaces(for: UUID())
        #expect(window.vaultWorkRoute == .tailscaleDetails(host.id))

        window.closeWorkspaces(for: host.id)
        #expect(window.vaultWorkRoute == nil)
    }

    @Test
    func changingVaultPageClosesRightColumnWork() {
        let window = WindowModel(vaultDestination: .hosts)

        window.openVaultWork(
            .snippetEditor(snippetID: nil, packageID: nil), on: .snippets
        )
        #expect(window.vaultDestination == .snippets)
        #expect(window.vaultWorkRoute == .snippetEditor(snippetID: nil, packageID: nil))

        window.openPage(.keychain)
        #expect(window.vaultDestination == .keychain)
        #expect(window.vaultWorkRoute == nil)
    }

    @Test
    func windowsKeepPresentationAndVaultSelectionIsolated() {
        let first = WindowModel(vaultDestination: .hosts)
        let second = WindowModel(vaultDestination: .hosts)
        let host = UUID()

        first.hostChooser = .connect
        first.selectVaultItem(.host(host), on: .hosts)

        #expect(first.hostChooser == .connect)
        #expect(second.hostChooser == nil)
        #expect(second.vaultSelection(for: .hosts).isEmpty)
    }

    @Test
    func windowPresentationRouteIsMutuallyExclusive() {
        let state = WindowPresentationState()

        state.hostChooser = .connect
        #expect(state.hostChooser == .connect)

        state.isQuickOpenPresented = true
        #expect(state.hostChooser == nil)
        #expect(state.isQuickOpenPresented)

        state.hostChooser = .batchStartup
        #expect(state.hostChooser == .batchStartup)
        #expect(!state.isQuickOpenPresented)

        state.hostChooser = nil
        #expect(state.route == nil)
    }

    @Test
    func featureRoutesReplaceRatherThanStack() {
        let window = WindowModel(vaultDestination: .hosts)
        let groupID = UUID()
        window.openVaultWork(
            .hostGroupEditor(groupID: nil, parentID: nil), on: .hosts
        )
        window.openVaultWork(
            .hostGroupEditor(groupID: groupID, parentID: nil), on: .hosts
        )
        #expect(
            window.vaultWorkRoute
                == .hostGroupEditor(groupID: groupID, parentID: nil)
        )

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
    func protectedVaultDeletionRequestsRemainPendingUntilConfirmed() {
        let host = Host(name: "Protected", host: "protected.example.invalid")
        let hosts = HostsPageState()

        hosts.requestDeletion(of: [host])

        guard case .deleteHosts(let pendingHosts) = hosts.confirmation else {
            Issue.record("Expected a pending Host deletion confirmation")
            return
        }
        #expect(pendingHosts.map(\.id) == [host.id])

        let identity = Identity(name: "Deploy", username: "deploy")
        let keychain = KeychainPageState()
        keychain.requestDeletion(of: [.identity(identity)])

        #expect(keychain.deleting == [.identity(identity)])
    }

    @Test
    func sessionsMixSSHAndSFTPInWorkspaceAndPaneOrder() {
        let firstHost = Host(name: "First", host: "first.example")
        let secondHost = Host(name: "Second", host: "second.example")
        let mixed = Workspace.sshSession(host: firstHost)
        let sshPane = mixed.focusedPane
        mixed.splitFocusedPane(axis: .horizontal, with: .sftpChannel(host: firstHost))
        let sftpPane = mixed.focusedPane
        let secondSSH = Workspace.sshSession(host: secondHost)
        let window = WindowModel(workspaces: [mixed, secondSSH])

        #expect(window.sessionPanes.map(\.pane.id) == [sshPane.id, sftpPane.id, secondSSH.focusedPane.id])
        #expect(window.sshSessionPanes.map(\.pane.id) == [sshPane.id, secondSSH.focusedPane.id])
        #expect(window.sftpChannelPanes.map(\.pane.id) == [sftpPane.id])
        #expect(window.sessionPanes.map(\.pane.symbol) == ["apple.terminal", "folder", "apple.terminal"])
    }

    @Test
    func sftpTitlesUseHostNameWithoutPrefixAndFallBackToSFTP() {
        let host = Host(name: "Uploads", host: "uploads.example")
        let store = HostLibraryModel(hosts: [host])
        let pane = Pane.sftpChannel(host: host)
        let missing = Pane(.sftpChannel(SFTPChannelModel(hostID: UUID(), initialPath: "/")))

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
        workspace.splitFocusedPane(axis: .horizontal, with: .sftpChannel(host: host))
        let sftpPane = workspace.focusedPane
        let window = WindowModel(workspaces: [workspace])

        workspace.focus(sshPane.id)
        window.select(workspace.id)

        workspace.focus(sftpPane.id)

        window.closePane(sftpPane.id)
        #expect(window.sessionPanes.map(\.pane.id) == [sshPane.id])
        #expect(workspace.focusedPaneID == sshPane.id)

        window.closePane(sshPane.id)
        #expect(window.sessionPanes.isEmpty)
        #expect(window.workspaces.isEmpty)
    }

    @Test
    func appRoutesHostsToSSHAndSFTPChannelsForWorkspaces() {
        let first = Host(name: "First", host: "first.example")
        let second = Host(name: "Second", host: "second.example")
        let store = HostLibraryModel(hosts: [first, second])
        let app = AppModel(hosts: store)
        let window = WindowModel()

        let sshTab = app.open(first, as: .sshSession, in: window)
        let sftpTab = app.open(second, as: .sftpChannel, in: window)
        #expect(sshTab.focusedPane.kind == .sshSession)
        #expect(sftpTab.focusedPane.kind == .sftpChannel)

        app.open([first, second], as: .sshSession, layout: .separateWorkspaces, in: window)
        #expect(window.selectedWorkspaceID == window.workspaces[2].id)
        #expect(window.workspaces.suffix(2).map(\.focusedPane.kind) == [.sshSession, .sshSession])

        app.open([first, second], as: .sftpChannel, layout: .oneWorkspace, in: window)
        #expect(window.selectedWorkspace?.panes.map(\.kind) == [.sftpChannel, .sftpChannel])
    }

    @Test
    func reopeningAClosedTerminalCreatesAFreshConnectingSession() throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let pane = workspace.focusedPane
        pane.customTitle = "Logs"
        let closedSession = try #require(pane.sshSession)
        let window = WindowModel(workspaces: [workspace])

        window.close(workspace.id)
        #expect(closedSession.status == .disconnected)
        #expect(window.canReopen)

        window.reopenLastClosed()

        let reopenedPane = try #require(window.selectedWorkspace?.focusedPane)
        let reopenedSession = try #require(reopenedPane.sshSession)
        #expect(reopenedSession !== closedSession)
        #expect(reopenedSession.hostID == host.id)
        #expect(reopenedSession.status == .connecting)
        #expect(reopenedPane.customTitle == "Logs")
        #expect(window.selectedWorkspace === workspace)
        #expect(!window.canReopen)
    }

    @Test(arguments: [false, true])
    func reopeningAClosedSplitPaneKeepsTheSurvivingSessionRunning(closeSelected: Bool) throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let survivor = workspace.focusedPane
        let survivorSession = try #require(survivor.sshSession)
        survivorSession.status = .connected
        let closedPane = Pane.sshSession(host: host)
        closedPane.customTitle = "Logs"
        let closedSession = try #require(closedPane.sshSession)
        closedSession.status = .connected
        workspace.splitFocusedPane(axis: .vertical, with: closedPane)
        workspace.broadcastsInput = true
        let window = WindowModel(workspaces: [workspace])

        if closeSelected {
            window.closeSelected()
        } else {
            window.closePane(closedPane.id)
        }

        #expect(window.canReopen)
        #expect(closedSession.status == .disconnected)
        #expect(workspace.panes.map(\.id) == [survivor.id])

        window.reopenLastClosed()

        let reopened = try #require(window.selectedWorkspace)
        let reopenedSession = try #require(reopened.focusedPane.sshSession)
        #expect(window.workspaces.count == 2)
        #expect(reopened !== workspace)
        #expect(reopened.panes.map(\.id) == [closedPane.id])
        #expect(reopened.focusedPane.customTitle == "Logs")
        #expect(reopenedSession !== closedSession)
        #expect(reopenedSession.hostID == host.id)
        #expect(reopenedSession.status == .connecting)
        #expect(reopenedSession.inputRouter === reopened)
        #expect(survivor.sshSession === survivorSession)
        #expect(survivorSession.status == .connected)
        #expect(survivorSession.inputRouter === workspace)
        #expect(!workspace.broadcastsInput && !reopened.broadcastsInput)
        #expect(!window.canReopen)
    }

    @Test
    func closedPanesAndWorkspacesReopenInReverseCloseOrder() throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let first = workspace.focusedPane
        let second = Pane.sftpChannel(host: host, initialPath: "/var/log")
        workspace.splitFocusedPane(axis: .horizontal, with: second)
        let other = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace, other])

        window.closePane(second.id)
        window.close(other.id)
        window.closePane(first.id)
        #expect(window.workspaces.isEmpty)

        window.reopenLastClosed()
        #expect(window.selectedWorkspace === workspace)
        #expect(workspace.panes.map(\.id) == [first.id])
        window.reopenLastClosed()
        #expect(window.selectedWorkspace === other)
        window.reopenLastClosed()
        let reopened = try #require(window.selectedWorkspace)
        #expect(reopened.panes.map(\.id) == [second.id])
        #expect(reopened.focusedPane.sftpChannel?.path == "/var/log")
        #expect(window.workspaces.count == 3)
        #expect(!window.canReopen)
    }

    @Test
    func individuallyClosedPanesShareTheTenItemReopenLimit() {
        let survivor = Pane(.empty)
        let workspace = Workspace(pane: survivor)
        let window = WindowModel(workspaces: [workspace])
        let closedPanes = (0..<11).map { _ in Pane(.empty) }
        for pane in closedPanes {
            workspace.splitFocusedPane(axis: .horizontal, with: pane)
            window.closePane(pane.id)
        }

        var reopenedIDs: [Pane.ID] = []
        while window.canReopen {
            window.reopenLastClosed()
            if let pane = window.selectedWorkspace?.focusedPane { reopenedIDs.append(pane.id) }
        }
        #expect(reopenedIDs == closedPanes.suffix(10).reversed().map(\.id))
        #expect(workspace.panes.map(\.id) == [survivor.id])

        window.closePane(reopenedIDs[0])
        #expect(window.canReopen)
        window.closeForWindow()
        #expect(!window.canReopen)
    }

    @Test
    func terminalPathOpensSFTPInANewWorkspaceOrTheCurrentWorkspace() {
        var host = Host(name: "Files", host: "files.example")
        host.sftpChannelInitialPath = "/configured"
        let sshWorkspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [sshWorkspace])

        let newTab = window.openSFTPChannel(
            host: host, initialPath: "/var/log/", placement: .newWorkspace
        )

        #expect(window.workspaces.count == 2)
        #expect(window.selectedWorkspace === newTab)
        #expect(newTab.focusedPane.sftpChannel?.path == "/var/log")
        #expect(newTab.focusedPane.sftpChannel?.initialPath == "/var/log")
        #expect(host.sftpChannelInitialPath == "/configured")

        window.select(sshWorkspace.id)
        let result = window.openSFTPChannel(
            host: host, initialPath: "/srv/app", placement: .currentWorkspace
        )

        #expect(result === sshWorkspace)
        #expect(window.workspaces.count == 2)
        #expect(sshWorkspace.panes.map(\.kind) == [.sshSession, .sftpChannel])
        #expect(sshWorkspace.focusedPane.sftpChannel?.path == "/srv/app")
    }

    @Test
    func sftpPathOpensSSHInANewWorkspaceOrTheCurrentWorkspace() throws {
        let host = Host(name: "Shell", host: "shell.example")
        let sftpWorkspace = Workspace.sftpChannel(host: host, initialPath: "/configured")
        let window = WindowModel(workspaces: [sftpWorkspace])

        let newTab = window.openSSHSession(
            host: host, initialPath: "/var/log", placement: .newWorkspace
        )

        #expect(window.workspaces.count == 2)
        #expect(window.selectedWorkspace === newTab)
        #expect(newTab.focusedPane.sshSession?.hostID == host.id)

        window.select(sftpWorkspace.id)
        let result = window.openSSHSession(
            host: host, initialPath: "/srv/app", placement: .currentWorkspace
        )

        #expect(result === sftpWorkspace)
        #expect(window.workspaces.count == 2)
        #expect(sftpWorkspace.panes.map(\.kind) == [.sftpChannel, .sshSession])
        #expect(sftpWorkspace.focusedPane.sshSession?.hostID == host.id)
    }

    @Test
    func sftpWithoutAnOverrideKeepsTheHostsConfiguredInitialPath() {
        var host = Host(name: "Files", host: "files.example")
        host.sftpChannelInitialPath = "/configured"
        let window = WindowModel()

        let workspace = window.openSFTPChannel(host: host)

        #expect(workspace.focusedPane.sftpChannel?.path == "/configured")
        #expect(workspace.focusedPane.sftpChannel?.initialPath == "/configured")
    }

    @Test
    func duplicateDestinationsPreservePaneAndWorkspaceScope() {
        let host = Host(name: "Host", host: "host.example")
        let original = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [original])

        window.duplicateSelected(axis: .horizontal)
        #expect(window.workspaces.count == 1)
        #expect(original.panes.count == 2)

        let focusedPane = original.focusedPane
        window.duplicatePaneInNewWorkspace()
        #expect(window.workspaces.count == 2)
        #expect(window.selectedWorkspace?.panes.count == 1)
        #expect(window.selectedWorkspace?.focusedPane.kind == focusedPane.kind)

        window.select(original.id)
        window.duplicateSelectedInNewWorkspace()
        #expect(window.workspaces.count == 3)
        #expect(window.selectedWorkspace?.panes.count == 2)
        #expect(window.selectedWorkspace?.panes.map(\.kind) == original.panes.map(\.kind))
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
        let window = WindowModel(workspaces: [workspace])

        firstSSHSession.handleRemoteExit(.success(0))

        #expect(window.workspaces.count == 1)
        #expect(workspace.panes.map(\.id) == [secondPane.id])
        #expect(workspace.layout.pane(firstPane.id) == nil)
        #expect(workspace.focusedPaneID == secondPane.id)
        #expect(!workspace.broadcastsInput)
        #expect(firstSSHSession.inputRouter == nil)
        #expect(window.canReopen)

        window.reopenLastClosed()

        #expect(window.selectedWorkspace?.focusedPane.id == firstPane.id)
        #expect(window.selectedWorkspace?.focusedPane.sshSession !== firstSSHSession)
        #expect(!window.canReopen)
    }

    @Test
    func normalRemoteExitClosesLastPaneAndSelectsNeighboringWorkspace() {
        let host = Host(name: "Host", host: "host.example")
        let sshSessionTab = Workspace.sshSession(host: host)
        let sshSession = sshSessionTab.focusedPane.sshSession!
        let neighbor = Workspace.sftpChannel(host: host)
        let window = WindowModel(workspaces: [sshSessionTab, neighbor])
        window.select(sshSessionTab.id)

        sshSession.handleRemoteExit(.success(0))

        #expect(window.workspaces.map(\.id) == [neighbor.id])
        #expect(window.selectedWorkspaceID == neighbor.id)
    }

    @Test
    func transportFailureKeepsPaneOpenForReconnect() {
        let host = Host(name: "Host", host: "host.example")
        let workspace = Workspace.sshSession(host: host)
        let sshSession = workspace.focusedPane.sshSession!
        let window = WindowModel(workspaces: [workspace])

        sshSession.handleRemoteExit(.failure(.disconnected))

        #expect(window.workspaces.map(\.id) == [workspace.id])
        #expect(workspace.focusedPane.sshSession === sshSession)
        guard case .failed = sshSession.status else {
            Issue.record("Expected transport failure to remain visible")
            return
        }
    }

    @Test
    func workspaceNamesUseTopLevelTitlesAcrossProtocolsAndHostIDs() {
        let first = Host(name: "Server", host: "first.example")
        let second = Host(name: "Server", host: "second.example", telnetEnabled: true)
        let store = HostLibraryModel(hosts: [first, second])
        let window = WindowModel()
        window.hostStore = store

        let ssh = window.openSSHSession(host: first)
        let sftp = window.openSFTPChannel(host: second)
        let telnet = window.openTelnetSession(host: second)
        #expect([ssh, sftp, telnet].map { $0.title(in: store) } == ["Server", "Server (1)", "Server (2)"])

        window.rename(sftp.id, to: "Logs")
        let next = window.openSSHSession(host: first)
        #expect(next.title(in: store) == "Server (3)")

        window.close(ssh.id)
        let reusedBase = window.openSFTPChannel(host: first)
        #expect(reusedBase.title(in: store) == "Server")
    }

    @Test
    func combinedPaneNamesAndOtherWindowsDoNotOccupyWorkspaceNames() {
        let host = Host(name: "Server 2", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let combined = Workspace.sshSession(host: host)
        combined.splitFocusedPane(axis: .horizontal, with: .sftpChannel(host: host))
        let window = WindowModel(workspaces: [combined])
        window.hostStore = store

        let first = window.openSSHSession(host: host)
        let second = window.openSFTPChannel(host: host)
        #expect(first.title(in: store) == "Server 2")
        #expect(second.title(in: store) == "Server 2 (1)")

        let otherWindow = WindowModel()
        otherWindow.hostStore = store
        #expect(otherWindow.openSSHSession(host: host).title(in: store) == "Server 2")
    }

    @Test
    func hostNamesThatEndInNumbersDoNotConflictWithParenthesizedSuffixes() {
        let server = Host(name: "Server", host: "server.example")
        let serverOne = Host(name: "Server 1", host: "server-one.example")
        let store = HostLibraryModel(hosts: [server, serverOne])
        let window = WindowModel()
        window.hostStore = store

        #expect(window.openSSHSession(host: server).title(in: store) == "Server")
        #expect(window.openSSHSession(host: serverOne).title(in: store) == "Server 1")
        #expect(window.openSSHSession(host: server).title(in: store) == "Server (1)")
        #expect(window.openSSHSession(host: serverOne).title(in: store) == "Server 1 (1)")
    }

    @Test
    func disablingAutomaticWorkspaceNamesLeavesExistingNamesAndStopsAddingNumbers() {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let window = WindowModel()
        window.hostStore = store
        let first = window.openSSHSession(host: host)
        let second = window.openSSHSession(host: host)
        window.workspacePreferences = {
            WorkspacePreferences(automaticallyRenamesWorkspaces: false)
        }
        let third = window.openSFTPChannel(host: host)

        #expect([first, second, third].map { $0.title(in: store) } == ["Server", "Server (1)", "Server"])
    }
}

private actor FailingConversationOperationRepository: AgentRunPersisting {
    private struct StorageFailure: LocalizedError {
        var errorDescription: String? { "Storage unavailable" }
    }

    func save(_ snapshot: AgentRunSnapshot) {}
    func record(_ event: AgentEvent, runID: UUID) {}
    func persistCompaction(
        _ record: AgentCompactionRecord, conversationID: UUID
    ) throws {
        throw StorageFailure()
    }
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(
        _ metadata: StoredAgentConversationMetadata, conversationID: UUID
    ) throws {
        throw StorageFailure()
    }
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) throws {
        throw StorageFailure()
    }
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) throws {
        throw StorageFailure()
    }
    func createConversation(_ conversation: StoredAgentConversation) throws {
        throw StorageFailure()
    }
}
