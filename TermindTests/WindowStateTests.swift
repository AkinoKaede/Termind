import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct WindowStateTests {
    @Test
    func assistantManualOrderMovesAcrossPinnedBoundaryAndStaysStableAfterActivity() throws {
        let first = ConversationModel(updatedAt: Date(timeIntervalSinceReferenceDate: 10))
        let second = ConversationModel(updatedAt: Date(timeIntervalSinceReferenceDate: 20))
        let pinned = ConversationModel(updatedAt: Date(timeIntervalSinceReferenceDate: 30))
        pinned.isPinned = true
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [first, second, pinned]
        ))

        let updates = try #require(library.orderUpdates(
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

    @Test
    func closingTheLastWorkspacePromotesTheVisibleSidebarConversationFullScreen() {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [conversation]
        ))
        let window = WindowModel(workspaces: [workspace], assistantLibrary: library)
        window.sidebarMode = .assistant
        window.openAssistantInSidebar(conversation.id)

        window.close(workspace.id)

        #expect(window.workspaces.isEmpty)
        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)
        #expect(window.sidebarMode == .assistant)
    }

    @Test
    func closingAllWorkspacesPromotesTheVisibleSidebarConversationFullScreen() {
        let workspace = Workspace.sshSession(
            host: Host(name: "Server", host: "server.example")
        )
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [conversation]
        ))
        let window = WindowModel(workspaces: [workspace], assistantLibrary: library)
        window.sidebarMode = .assistant
        window.openAssistantInSidebar(conversation.id)

        window.closeAll()

        #expect(window.workspaces.isEmpty)
        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)
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
        let library = AssistantLibraryModel(store: AssistantConversationStore(
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
        let library = AssistantLibraryModel(store: AssistantConversationStore(
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
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [conversation]
        ))
        let window = WindowModel(assistantLibrary: library)
        window.selectAssistant(conversation.id)
        window.openAssistantInSidebar(conversation.id)

        window.setAssistantArchived(conversation.id, archived: true)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(window.sidebar.assistantConversationID == nil)
        #expect(!window.sidebar.isAssistantArchivePresented)
    }

    @Test
    func archiveIsASeparateWindowDestinationAndConversationNavigationLeavesIt() {
        let conversation = ConversationModel()
        conversation.archivedAt = .now
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [conversation]
        ))
        let window = WindowModel(assistantLibrary: library)

        window.showAssistantArchive()
        #expect(window.isAssistantArchivePresented)
        #expect(window.selectedDestination == .assistant)

        window.selectAssistant(conversation.id)
        #expect(!window.isAssistantArchivePresented)
        #expect(window.assistantLibrary.selectedConversation === conversation)

        window.showAssistantArchiveInSidebar()
        #expect(window.sidebar.isAssistantArchivePresented)
        #expect(window.sidebarAssistantConversation == nil)

        window.openAssistantInSidebar(conversation.id)
        #expect(!window.sidebar.isAssistantArchivePresented)
        #expect(window.sidebarAssistantConversation === conversation)
    }

    @Test
    func openingSidebarConversationFullScreenKeepsAssistantSidebarSelected() {
        let conversation = ConversationModel()
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [conversation]
        ))
        let window = WindowModel(assistantLibrary: library)

        window.openAssistantFullScreen(conversation.id)

        #expect(window.selectedDestination == .assistant)
        #expect(window.assistantLibrary.selectedConversation === conversation)
        #expect(window.sidebarMode == .assistant)
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

    @Test
    func failedMetadataSaveKeepsConversationStateAndReportsTheError() async {
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

        window.toggleAssistantPin(conversation.id)
        for _ in 0..<100 {
            if window.assistantOperationError != nil { break }
            await Task.yield()
        }

        #expect(!conversation.isPinned)
        #expect(window.assistantOperationError == "Storage unavailable")
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
        conversation.appendUserTurn("old " + String(repeating: "x", count: 4_000))
        conversation.appendUserTurn("recent")
        let span = try #require(conversation.compactionSpan(keepRecentTokens: 2))
        let record = try #require(conversation.prepareCompaction(
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
        let library = AssistantLibraryModel(store: AssistantConversationStore(
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
        let library = AssistantLibraryModel(store: AssistantConversationStore(
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
        let library = AssistantLibraryModel(store: AssistantConversationStore(
            conversations: [conversation]
        ))
        let window = WindowModel(assistantLibrary: library)

        window.selectAssistant(conversation.id)
        window.showAssistantArchive()
        window.selectVault()
        window.activateSidebarMode(.assistant)

        #expect(window.isAssistantArchivePresented)
        #expect(window.assistantLibrary.selectedConversation === conversation)
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
    func newChatJoinsHistoryOnlyAfterItsFirstSend() {
        let window = WindowModel()
        let draft = window.openNewAssistantChat()

        #expect(window.assistantLibrary.selectedConversation == nil)
        #expect(window.assistantLibrary.conversations.isEmpty)

        draft.composer.draft = "Hello from a new chat"
        let started = window.assistantLibrary.startDraftConversation()

        #expect(started === draft)
        #expect(window.assistantLibrary.selectedConversation === draft)
        #expect(window.assistantLibrary.conversations.map(\.id) == [draft.id])
        #expect(window.assistantLibrary.draftConversation !== draft)
    }

    @Test
    func sidebarDraftCreatesConversationOnlyOnFirstValidSend() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let window = WindowModel(workspaces: [workspace])

        #expect(window.sendAssistantSidebarDraft() == nil)
        #expect(window.assistantLibrary.conversations.isEmpty)

        window.sidebar.assistantDraft.composer.draft = "  Explain this failure.  "
        let conversation = window.sendAssistantSidebarDraft()

        #expect(conversation?.messages.map(\.text) == ["Explain this failure."])
        #expect(window.assistantLibrary.conversations.count == 1)
        #expect(window.assistantLibrary.conversations.first?.id == conversation?.id)
        #expect(window.sidebarAssistantConversation?.id == conversation?.id)
        #expect(window.selectedDestination == .workspace(workspace.id))
        #expect(window.sidebar.assistantDraft.isEmpty)
    }

    @Test
    func sidebarConversationNavigationIsIndependentAndDeletionReturnsHome() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let conversation = ConversationModel()
        conversation.composer.draft = "Hello"
        let library = AssistantLibraryModel()
        _ = library.startConversation(conversation)
        let window = WindowModel(workspaces: [workspace], assistantLibrary: library)

        window.openAssistantInSidebar(conversation.id)
        #expect(window.sidebarAssistantConversation?.id == conversation.id)
        #expect(window.selectedDestination == .workspace(workspace.id))

        window.closeAssistantInSidebar()
        #expect(window.sidebarAssistantConversation == nil)

        window.openAssistantInSidebar(conversation.id)
        window.deleteAssistantConversation(conversation.id)
        #expect(window.sidebarAssistantConversation == nil)
        #expect(window.assistantLibrary.conversations.isEmpty)
    }

    @Test
    func assistantSidebarShowsFocusedWorkspaceContext() {
        let host = Host(name: "Files", host: "files.example")
        let workspace = Workspace.sftpSession(host: host, initialPath: "/srv/app")
        workspace.focusedPane.sftpSession?.homeResolution = .unavailable
        let window = WindowModel(workspaces: [workspace])

        window.hostStore = HostLibraryModel(hosts: [host])

        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host, .directory])
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/srv/app"])
        // The id the host tools require, taken from the focused pane rather than
        // left for the model to guess from the name.
        #expect(window.sidebar.sessionContext.hostID == workspace.focusedPane.hostID)
        #expect(window.sidebar.sessionContext.hostID == host.id)
    }

    @Test
    func focusedSFTPPathChangesUpdateSessionContext() {
        let host = Host(name: "Files", host: "files.example")
        let workspace = Workspace.sftpSession(host: host, initialPath: "/srv")
        let sftpSession = workspace.focusedPane.sftpSession!
        sftpSession.homeResolution = .unavailable
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])

        sftpSession.navigate(to: "/srv/releases")

        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host, .directory])
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/srv/releases"])

        sftpSession.goBack()
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Files", "/srv"])
    }

    @Test
    func backgroundSFTPPathDoesNotReplaceFocusedPaneContext() {
        let host = Host(name: "Files", host: "files.example")
        let workspace = Workspace.sftpSession(host: host, initialPath: "/focused")
        let focusedPane = workspace.focusedPane
        focusedPane.sftpSession?.homeResolution = .unavailable
        workspace.splitFocusedPane(
            axis: .horizontal,
            with: .sftpSession(host: host, initialPath: "/background")
        )
        let backgroundSession = workspace.focusedPane.sftpSession!
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
    func sendingFromTheSidebarDoesNotAttachSessionContextToTheConversation() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sftpSession(host: host, initialPath: "/srv/app")
        workspace.focusedPane.sftpSession?.homeResolution = .unavailable
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])
        window.sidebar.assistantDraft.composer.draft = "Why is this slow?"

        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Server", "/srv/app"])

        let conversation = window.sendAssistantSidebarDraft()

        #expect(conversation?.composer.attachments.isEmpty == true)
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Server", "/srv/app"])
    }

    /// Leaving every Workspace used to freeze the last host and directory on
    /// screen, because the refresh returned early instead of clearing.
    @Test
    func leavingEveryWorkspaceClearsSessionContext() {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sftpSession(host: host, initialPath: "/srv/app")
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])

        #expect(!window.sidebar.sessionContext.isEmpty)

        window.selectVault()
        window.refreshSessionContext()

        #expect(window.sidebar.sessionContext == .none)
    }

    /// The path `askAI` takes: attach the failure log, promote the draft, and
    /// the log goes with the message it belongs to rather than sitting in the
    /// draft as text the user could half-delete.
    @Test
    func promotingASidebarDraftSendsItsAttachmentWithTheFirstTurn() {
        let conversation = ConversationModel()
        conversation.attach(
            ContextChip(kind: .output, label: "Connection error", content: "ssh: refused")
        )
        conversation.composer.draft = "Explain this"

        _ = AssistantLibraryModel().startConversation(conversation)

        #expect(conversation.messages.first?.text == "Explain this")
        #expect(conversation.transcript.first?.text.contains("ssh: refused") == true)
        #expect(conversation.composer.attachments.isEmpty, "the attachment went with the turn")
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
        _ = library.startConversation(conversation)
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
    func focusedSSHDirectoryChangesUpdateSessionContext() async {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let sshSession = workspace.focusedPane.sshSession!
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = HostLibraryModel(hosts: [host])
        sshSession.receiveShellIntegrationEvent(.homeResolutionUnavailable)

        sshSession.terminalState.terminalDidChangeWorkingDirectory("/var/log")
        await Task.yield()

        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host, .directory])
        #expect(window.sidebar.sessionContext.chips.map(\.label) == ["Server", "/var/log"])

        sshSession.disconnect()
        #expect(window.sidebar.sessionContext.chips.map(\.kind) == [.host])
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

        workspace.splitFocusedPane(axis: .horizontal, with: .sftpSession(host: host))
        #expect(window.sidebar.sessionContext.systemInfo == nil)

        workspace.focus(sshPane.id)
        #expect(window.sidebar.sessionContext.systemInfo == info)

        sshSession.applyShellIntegrationPreference(isEnabled: false)
        #expect(window.sidebar.sessionContext.systemInfo == nil)

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

    @Test
    func draggingSelectedWorkspaceDisplaysNeighbourAsMergeTarget() {
        let first = Workspace.sshSession(host: Host(name: "First", host: "first.example"))
        let second = Workspace.sshSession(host: Host(name: "Second", host: "second.example"))
        let window = WindowModel(workspaces: [first, second])
        window.select(first.id)

        window.dragging = .workspace(first.id)

        #expect(window.displayedWorkspace?.id == second.id)
        #expect(window.selectedWorkspace?.id == first.id)
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
    func sessionsMixSSHAndSFTPInWorkspaceAndPaneOrder() {
        let firstHost = Host(name: "First", host: "first.example")
        let secondHost = Host(name: "Second", host: "second.example")
        let mixed = Workspace.sshSession(host: firstHost)
        let sshPane = mixed.focusedPane
        mixed.splitFocusedPane(axis: .horizontal, with: .sftpSession(host: firstHost))
        let sftpPane = mixed.focusedPane
        let secondSSH = Workspace.sshSession(host: secondHost)
        let window = WindowModel(workspaces: [mixed, secondSSH])

        #expect(window.sessionPanes.map(\.pane.id) == [sshPane.id, sftpPane.id, secondSSH.focusedPane.id])
        #expect(window.sshSessionPanes.map(\.pane.id) == [sshPane.id, secondSSH.focusedPane.id])
        #expect(window.sftpSessionPanes.map(\.pane.id) == [sftpPane.id])
        #expect(window.sessionPanes.map(\.pane.symbol) == ["apple.terminal", "folder", "apple.terminal"])
    }

    @Test
    func sftpTitlesUseHostNameWithoutPrefixAndFallBackToSFTP() {
        let host = Host(name: "Uploads", host: "uploads.example")
        let store = HostLibraryModel(hosts: [host])
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
    func appRoutesHostsToSSHAndSFTPSessionsForWorkspaces() {
        let first = Host(name: "First", host: "first.example")
        let second = Host(name: "Second", host: "second.example")
        let store = HostLibraryModel(hosts: [first, second])
        let app = AppModel(hosts: store)
        let window = WindowModel()

        let sshTab = app.open(first, as: .sshSession, in: window)
        let sftpTab = app.open(second, as: .sftpSession, in: window)
        #expect(sshTab.focusedPane.kind == .sshSession)
        #expect(sftpTab.focusedPane.kind == .sftpSession)

        app.open([first, second], as: .sshSession, layout: .separateWorkspaces, in: window)
        #expect(window.selectedWorkspaceID == window.workspaces[2].id)
        #expect(window.workspaces.suffix(2).map(\.focusedPane.kind) == [.sshSession, .sshSession])

        app.open([first, second], as: .sftpSession, layout: .oneWorkspace, in: window)
        #expect(window.selectedWorkspace?.panes.map(\.kind) == [.sftpSession, .sftpSession])
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

    @Test
    func terminalPathOpensSFTPInANewWorkspaceOrTheCurrentWorkspace() {
        var host = Host(name: "Files", host: "files.example")
        host.sftpSessionInitialPath = "/configured"
        let sshWorkspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [sshWorkspace])

        let newTab = window.openSFTPSession(
            host: host, initialPath: "/var/log/", placement: .newWorkspace
        )

        #expect(window.workspaces.count == 2)
        #expect(window.selectedWorkspace === newTab)
        #expect(newTab.focusedPane.sftpSession?.path == "/var/log")
        #expect(newTab.focusedPane.sftpSession?.initialPath == "/var/log")
        #expect(host.sftpSessionInitialPath == "/configured")

        window.select(sshWorkspace.id)
        let result = window.openSFTPSession(
            host: host, initialPath: "/srv/app", placement: .currentWorkspace
        )

        #expect(result === sshWorkspace)
        #expect(window.workspaces.count == 2)
        #expect(sshWorkspace.panes.map(\.kind) == [.sshSession, .sftpSession])
        #expect(sshWorkspace.focusedPane.sftpSession?.path == "/srv/app")
    }

    @Test
    func sftpPathOpensSSHInANewWorkspaceOrTheCurrentWorkspace() throws {
        let host = Host(name: "Shell", host: "shell.example")
        let sftpWorkspace = Workspace.sftpSession(host: host, initialPath: "/configured")
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
        #expect(sftpWorkspace.panes.map(\.kind) == [.sftpSession, .sshSession])
        #expect(sftpWorkspace.focusedPane.sshSession?.hostID == host.id)
    }

    @Test
    func sshDirectoryCommandQuotesRemotePaths() {
        #expect(
            WindowModel.changeDirectoryCommand(for: "/srv/it's live")
                == "cd '/srv/it'\"'\"'s live'"
        )
        #expect(WindowModel.changeDirectoryCommand(for: "") == nil)
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
    }

    @Test
    func normalRemoteExitClosesLastPaneAndSelectsNeighboringWorkspace() {
        let host = Host(name: "Host", host: "host.example")
        let sshSessionTab = Workspace.sshSession(host: host)
        let sshSession = sshSessionTab.focusedPane.sshSession!
        let neighbor = Workspace.sftpSession(host: host)
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
