import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

enum SessionOpenPlacement: Equatable {
    case newWorkspace
    case currentWorkspace
}

protocol WindowRemoteTitleSink: AnyObject {
    func windowRemoteTitleDidChange(_ title: String?)
}

/// The state of one window: its workspaces, selection, and shared left sidebar.
///
/// One of these per window rather than one per app, so two windows can hold
/// different sets of workspaces. Menu commands reach the right instance through
/// `FocusedValues.window`.
@Observable
final class WindowModel {
    private(set) var isClosed = false
    let workspaceDeck: WorkspaceDeckModel
    var workspaces: [Workspace] {
        get { workspaceDeck.workspaces }
        set { workspaceDeck.workspaces = newValue }
    }
    /// The top-level shell has Vault, Assistant, Settings, and dynamic SSH/SFTP
    /// Workspaces. This is the single source of truth for workspace selection.
    var selectedDestination: WindowDestination = .vault {
        didSet {
            if selectedDestination != oldValue {
                publishRemoteWindowTitle()
            }
            if selectedDestination != .assistant {
                assistantReturnDestination = selectedDestination
            }
            reconcileSidebarMode()
        }
    }
    @ObservationIgnored weak var remoteWindowTitleSink: (any WindowRemoteTitleSink)?
    /// Where Navigator returns after the Assistant temporarily replaces the
    /// detail surface. Assistant has no row inside the Navigator that could
    /// retain the previous selection for us.
    private var assistantReturnDestination: WindowDestination = .vault
    /// Settings is a reversible trip from the content in front. Its own route is
    /// window-scoped so two windows can configure shared preferences independently.
    private var settingsReturnDestination: WindowDestination = .vault
    weak var metricsModel: ServerMetricsModel?
    var pendingMetricsHostIDs: [UUID] = []
    var metricsHostID: UUID? {
        didSet {
            if metricsHostID != oldValue { metricsDetailPage = .status }
        }
    }
    var metricsDetailPage = MetricsDetailPage.status
    var metricsDetailWidth: CGFloat = 0 {
        didSet {
            if isToolbarFindFocused { revealMetricsProcessesForFind() }
        }
    }
    var showsCompactMetricsDetail: Bool {
        guard selectedDestination == .metrics, metricsDetailWidth > 0,
            !MetricsDetailPage.showsBothColumns(width: metricsDetailWidth),
            let server = metricsModel?.servers.first(where: { $0.id == metricsHostID })
        else { return false }
        return !server.showsConnectionJourney
    }
    var metricsQuery = ""
    var metricsProcessQuery = "" {
        didSet {
            if isToolbarFindFocused { revealMetricsProcessesForFind() }
        }
    }
    var metricsSelection: Set<UUID> = []
    var settingsRoute: SettingsRoute = .index
    var vaultDestination: VaultDestination = .welcome
    var vaultWorkRoute: VaultWorkRoute?
    let assistantLibrary: AssistantLibraryModel
    /// Native transcript views survive destination and conversation switches,
    /// while remaining window-local and bounded in memory.
    let transcriptCache = TranscriptListCache()
    let sidebar = WindowSidebarState()
    let presentations = WindowPresentationState()
    let dragState = WorkspaceDragState()
    /// Query and confirmation state for the three manager pages, kept here so a
    /// half-typed search survives a trip to another page — see `VaultPageStates`.
    let vaultPages = VaultPageStates()
    /// What the titlebar Find field holds while the Assistant is in front.
    /// Deliberately window-local and never persisted: a search is a way of
    /// looking at the list, not a property of it.
    var assistantQuery = ""
    /// Archived chats are a destination, not a third section in live history.
    /// This remains window-local so two windows may independently manage the
    /// archive and continue a conversation.
    var isAssistantArchivePresented = false
    var connectionCoordinator: RemoteConnectionCoordinator? {
        didSet {
            guard let connectionCoordinator else { return }
            for workspace in workspaces {
                workspace.configureConnections(using: connectionCoordinator)
            }
        }
    }
    weak var commandHistoryStore: CommandHistoryModel? {
        didSet {
            guard let commandHistoryStore else { return }
            for workspace in workspaces { workspace.configureCommandHistory(using: commandHistoryStore) }
        }
    }
    weak var sftpHistoryStore: SFTPHistoryModel? {
        didSet {
            guard let sftpHistoryStore else { return }
            for workspace in workspaces { workspace.configureSFTPHistory(using: sftpHistoryStore) }
        }
    }
    var assistantCommands: AssistantConversationCommands?
    var assistantOperationError: String?
    var workspaceTemplateNotice: String?
    var hostStore: HostLibraryModel? {
        didSet {
            refreshSessionContext()
        }
    }

    /// What is being dragged right now, from the workspace bar or from a pane.
    ///
    /// Held on the model because every drop target has to decide things *during*
    /// the drag: whether to draw itself without the thing in flight, where a
    /// ghost slot should open, and whether the drop will move a pane or fold in
    /// a whole workspace. The pasteboard payload resolves asynchronously, one drop too
    /// late to answer any of them.
    ///
    /// A drag released over nothing leaves this set. That is harmless — nothing
    /// moves without a `performDrop` — and the next drag overwrites it.
    var dragging: DragPayload? {
        get { dragState.payload }
        set { dragState.payload = newValue }
    }

    /// Ordered selection saved for a Vault manager page.
    func vaultSelection(for page: VaultPage) -> [VaultSelectionID] {
        vaultPages.selection.selection(for: page)
    }

    /// Replaces a page selection, removing duplicates and ids belonging to a
    /// different page while keeping the first occurrence of each item.
    func setVaultSelection(_ details: [VaultSelectionID], for page: VaultPage) {
        vaultPages.selection.set(details, for: page)
    }

    func selectVaultItem(_ detail: VaultSelectionID, on page: VaultPage) {
        vaultPages.selection.select(detail, on: page)
    }

    /// Shift-click semantics: selected items retain their order; a newly added
    /// item is appended at the point the user selected it.
    func toggleVaultItem(_ detail: VaultSelectionID, on page: VaultPage) {
        vaultPages.selection.toggle(detail, on: page)
    }

    func clearVaultSelection(for page: VaultPage) {
        vaultPages.selection.clear(page)
    }

    /// Removes records deleted out from under a remembered selection.
    func pruneVaultSelections(in store: HostLibraryModel) {
        vaultPages.selection.prune(available: Self.availableVaultSelections(in: store))
    }

    func pruneVaultSelections(in store: CredentialLibraryModel) {
        let available = Set(store.keys.map { VaultSelectionID.key($0.id) })
            .union(store.identities.map { .identity($0.id) })
        vaultPages.selection.prune(available: available, pages: [.keychain])
    }

    func pruneVaultSelections(in store: SnippetLibraryModel) {
        vaultPages.selection.prune(
            available: Set(store.snippets.map { VaultSelectionID.snippet($0.id) }), pages: [.snippets]
        )
    }

    private static func availableVaultSelections(in store: HostLibraryModel) -> Set<VaultSelectionID> {
        Set(store.hosts.map { .host($0.id) })
            .union(store.keys.map { .key($0.id) })
            .union(store.identities.map { .identity($0.id) })
            .union(store.portForwardings.map { .forwarding($0.id) })
            .union(store.snippets.map { .snippet($0.id) })
            .union(store.knownHosts.map { .knownHost($0.id) })
    }

    typealias SidebarMode = WindowSidebarState.Mode

    var showsSidebar: Bool {
        get { sidebar.isPresented }
        set { sidebar.isPresented = newValue }
    }

    var availableSidebarModes: [SidebarMode] {
        SidebarMode.allCases.filter(isSidebarModeEnabled)
    }

    var sidebarMode: SidebarMode {
        get { sidebar.mode }
        set {
            guard isSidebarModeEnabled(newValue) else { return }
            sidebar.mode = newValue
        }
    }

    func isSidebarModeEnabled(_ mode: SidebarMode) -> Bool {
        mode != .history || focusedSerialSession == nil
    }

    func reconcileSidebarMode() {
        if !isSidebarModeEnabled(sidebarMode) {
            sidebar.mode = .snippets
        }
    }

    /// Applies a Sidebar mode chosen by the user, including the two mode-rail
    /// buttons that also act as top-level navigation affordances.
    ///
    /// Direct `sidebarMode` assignment deliberately remains presentation-only
    /// for restoration, screenshots, and other programmatic configuration.
    func activateSidebarMode(_ mode: SidebarMode) {
        guard isSidebarModeEnabled(mode) else { return }
        sidebarMode = mode

        switch mode {
        case .assistant:
            // Inside a Workspace this is its compact, context-aware Assistant.
            // Everywhere else the same control opens the full Assistant route.
            if selectedWorkspace == nil {
                selectAssistant()
            }
        case .navigation:
            if selectedDestination == .assistant {
                restoreAssistantReturnDestination()
            }
        case .snippets, .history:
            break
        }
    }

    private func restoreAssistantReturnDestination() {
        switch assistantReturnDestination {
        case .workspace(let id):
            if workspaces.contains(where: { $0.id == id }) {
                select(id)
            } else {
                selectVault()
            }
        case .vault:
            selectVault()
        case .assistant:
            // Defensive only: the remembered destination is updated exclusively
            // from non-Assistant routes.
            selectVault()
        case .metrics:
            selectedDestination = .metrics
        case .settings:
            selectedDestination = .settings
        }
    }

    /// Opens the shared column and selects the current Workspace's assistant.
    /// Repeating the command is intentionally idempotent; hiding the column is
    /// the native Toggle Sidebar command's job.
    func showAssistant() {
        guard selectedWorkspace != nil else { return }
        refreshSessionContext()
        sidebar.isPresented = true
        sidebarMode = .assistant
    }

    var hostChooser: HostChooserPurpose? {
        get { presentations.hostChooser }
        set { presentations.hostChooser = newValue }
    }

    var isQuickOpenPresented: Bool {
        get { presentations.isQuickOpenPresented }
        set {
            presentations.isQuickOpenPresented = newValue
            if newValue { isToolbarFindFocused = false }
        }
    }

    /// Closed workspaces, most recent last. ⇧⌘T pops from here. The Workspace retains
    /// its layout, names, and conversation, while `prepareForReopen` replaces
    /// terminal models because a dead SSH session cannot be revived.
    private var reopenStack: [Workspace] {
        get { workspaceDeck.reopenStack }
        set { workspaceDeck.reopenStack = newValue }
    }

    init(
        workspaces: [Workspace] = [],
        vaultDestination: VaultDestination = .welcome,
        assistantLibrary: AssistantLibraryModel = AssistantLibraryModel()
    ) {
        self.workspaceDeck = WorkspaceDeckModel(workspaces: workspaces)
        self.vaultDestination = vaultDestination
        self.assistantLibrary = assistantLibrary
        selectedDestination = workspaces.first.map { .workspace($0.id) } ?? .vault
        // Property observers do not run while an instance is being initialized.
        assistantReturnDestination = selectedDestination
        settingsReturnDestination = selectedDestination
        for workspace in workspaces {
            workspace.lifecycleRouter = self
        }
    }

    // MARK: - Selection

    var selectedWorkspace: Workspace? {
        guard case .workspace(let selectedWorkspaceID) = selectedDestination else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedWorkspaceID: Workspace.ID? {
        get {
            guard case .workspace(let id) = selectedDestination else { return nil }
            return id
        }
        set {
            selectedDestination = newValue.map(WindowDestination.workspace) ?? .vault
        }
    }

    /// The only pane that application-wide find commands may touch. A Workspace
    /// can contain several terminals, so routing to "any session in the workspace"
    /// would make ⌘F search a buffer other than the one under the caret.
    var focusedSSHSession: SSHSessionModel? {
        return selectedWorkspace?.focusedPane.sshSession
    }

    var focusedSFTPChannel: SFTPChannelModel? {
        selectedWorkspace?.focusedPane.sftpChannel
    }

    var focusedSerialSession: SerialSessionModel? {
        selectedWorkspace?.focusedPane.serialSession
    }

    var canFindInTerminal: Bool { focusedSSHSession != nil || focusedSerialSession != nil }

    var canGenerateTerminalCommand: Bool { focusedSSHSession != nil }

    func generateTerminalCommand(using controller: CommandGeneratorController) {
        selectedWorkspace?.generateFocusedCommand(using: controller)
    }

    // MARK: - Find

    /// Bumped by ⌘F. The titlebar field watches it and takes first responder,
    /// so pressing ⌘F while the field is already showing refocuses rather than
    /// doing nothing.
    private(set) var findFocusRequest: UInt64 = 0

    /// Bumped by ⌘F while Welcome is in front. Welcome owns a large search
    /// field in its content instead of borrowing the titlebar Find field.
    private(set) var welcomeSearchFocusRequest: UInt64 = 0

    /// True while the titlebar Find field owns the keyboard.
    ///
    /// The field is outside every pane, but what it filters is inside one — so
    /// typing in it changes state the pane observes, and a pane that claims
    /// first responder whenever it is the focused pane takes the caret back
    /// after each keystroke. Panes read this and stand down while it is set.
    ///
    /// Level, not edge. A pane has to consult it every time it is about to hold
    /// focus, not only when this flips: the caret is lost on *each* keystroke,
    /// and a stand-down that fires once cannot answer the second one.
    var isToolbarFindFocused = false {
        didSet {
            if isToolbarFindFocused { revealMetricsProcessesForFind() }
        }
    }

    private func revealMetricsProcessesForFind() {
        if showsCompactMetricsDetail { metricsDetailPage = .processes }
    }

    /// Focuses the titlebar Find field. Installed by the field itself while it
    /// is mounted, and left pointing at a field that has gone away otherwise —
    /// harmlessly, since the closure holds it weakly and `focusToolbarFind`
    /// checks there is something to search first.
    ///
    /// ⌘F does not go through `findFocusRequest` alone. That counter only
    /// reaches the field if SwiftUI delivers an update to the toolbar item
    /// holding it, which is not a refresh this code owns.
    @ObservationIgnored var focusToolbarFindField: (() -> Void)?

    /// What the window's one Find field is pointed at, decided by the content in
    /// front. A split Workspace resolves to its *focused* pane — "any session in
    /// the workspace" would make ⌘F search a buffer other than the one under the
    /// caret.
    var findKind: WindowToolbarFindKind? {
        switch selectedDestination {
        case .assistant:
            return .assistant
        case .metrics:
            return metricsHostID == nil ? .metrics : .processes
        case .settings:
            return nil
        case .workspace:
            if focusedSSHSession != nil || focusedSerialSession != nil { return .terminal }
            if focusedSFTPChannel != nil { return .sftp }
            return nil
        case .vault:
            switch vaultDestination {
            // Welcome has its own field, and it is the page's whole point.
            case .welcome: return nil
            case .hosts: return .hosts
            case .keychain: return .keychain
            case .portForwarding: return .portForwarding
            case .snippets: return .snippets
            case .knownHosts: return .knownHosts
            }
        }
    }

    private var hasWelcomeSearch: Bool {
        guard case .vault = selectedDestination else { return false }
        return vaultDestination == .welcome
    }

    var canFindInMainContent: Bool { hasWelcomeSearch || findKind != nil }

    /// ⌘F. Focuses the titlebar field, and for a terminal also starts Ghostty's
    /// search again on a query retained from last time.
    ///
    /// The panes are stood down *first*. Everything after this line changes
    /// state a pane observes, so by the time the resulting update reaches one it
    /// must already know not to claim the keyboard — otherwise ⌘F focuses the
    /// field and the rebuild it caused takes the caret straight back, which is
    /// how the Find menu item came to be clickable and yet do nothing.
    func focusToolbarFind() {
        if hasWelcomeSearch {
            welcomeSearchFocusRequest &+= 1
            return
        }
        guard findKind != nil else { return }
        isToolbarFindFocused = true
        if findKind == .terminal {
            focusedSSHSession?.find.present()
            focusedSerialSession?.find.present()
        }
        findFocusRequest &+= 1
        // On the next turn, so the update the two lines above set off has
        // already landed and cannot take the caret straight back out.
        Task { @MainActor [weak self] in self?.focusToolbarFindField?() }
    }

    /// ⌘G and F3.
    ///
    /// A terminal search starts at the bottom of the buffer, so Ghostty's
    /// `.previous` is the direction that reaches the first match — which is what
    /// a reader means by "next". Return in the Find field is bound the same way;
    /// the two used to disagree.
    func navigateTerminalFind(_ direction: TerminalFindDirection) {
        focusedSSHSession?.find.presentAndNavigate(direction)
        focusedSerialSession?.find.presentAndNavigate(direction)
    }

    /// The workspace whose content the detail column shows.
    ///
    /// The selected one, except while the selected one is the thing being
    /// dragged. Merging is done by dropping a workspace into a Workspace's pane area,
    /// and a workspace cannot be dropped into itself — so leaving it on screen would
    /// point the app's one merge gesture at the only target that refuses it.
    /// It steps aside to the next workspace, or the previous one when there is no
    /// next: strictly adjacent, and only when that neighbour is somewhere a workspace
    /// could actually land.
    ///
    /// Derived rather than a real selection change, the same way
    /// `WorkspaceContentView.displayedLayout` draws a Workspace without the pane in
    /// flight. Nothing is committed, so every way a drag can end — a reorder, a
    /// merge, a cancel, a release outside the window that no delegate ever hears
    /// about — puts the view back by itself. Storing it would mean an unwind path
    /// for each of those, and the last one has no callback to unwind from.
    var displayedWorkspace: Workspace? {
        guard case .workspace(let id)? = dragging,
            id == selectedWorkspaceID,
            let index = workspaces.firstIndex(where: { $0.id == id }),
            workspaces[index].isCombinable
        else { return selectedWorkspace }
        for neighbour in [index + 1, index - 1] where workspaces.indices.contains(neighbour) {
            if workspaces[neighbour].acceptsMerge { return workspaces[neighbour] }
        }
        return selectedWorkspace
    }

    /// Every pane of a given kind, with the Workspace holding it.
    ///
    /// The sidebar lists *panes*, not workspaces. A Workspace can be mixed — a shell
    /// beside a file browser — and it belongs under both Sessions and File
    /// Transfers rather than under whichever half had focus last. Filing the
    /// whole workspace by its focused pane meant a row that changed sections as you
    /// clicked around inside it, which is the one way a list of what is open can
    /// be worse than no list.
    ///
    /// It also means a Workspace with three shells gets three rows, which is the
    /// point of naming panes — see `Pane.customTitle`.
    func panes(ofKind kind: PaneKind) -> [PaneRef] {
        workspaces.flatMap { workspace in
            workspace.panes
                .filter { $0.kind == kind }
                .map(PaneRef.init(pane:))
        }
    }

    /// Shells on a host — what the sidebar lists under "Sessions", and what
    /// "Close All Sessions" acts on.
    ///
    /// Deliberately narrower than "not a page": a host editor is a form, a chat
    /// is a conversation, and a host's tunnels are a setting on that host. None
    /// of them is an SSH session no matter how it got opened.
    var sshSessionPanes: [PaneRef] { panes(ofKind: .sshSession) }

    /// One host's file browser, per open browser. The queue page is not among
    /// them: it is a page, so its `kind` is `.page`, and it lives in Manage.
    var sftpChannelPanes: [PaneRef] { panes(ofKind: .sftpChannel) }

    var serialSessionPanes: [PaneRef] { panes(ofKind: .serialSession) }

    var sessionPanes: [PaneRef] {
        workspaces.flatMap { workspace in
            workspace.panes.compactMap { pane in
                guard
                    pane.kind == .sshSession || pane.kind == .sftpChannel
                        || pane.kind == .serialSession
                else { return nil }
                return PaneRef(pane: pane)
            }
        }
    }

    var canReopen: Bool { !reopenStack.isEmpty }

    func select(_ id: Workspace.ID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedDestination = .workspace(id)
        workspaces.first { $0.id == id }?.markRead()
        refreshSessionContext()
    }

    func selectVault() {
        selectedDestination = .vault
    }

    /// Enters the Assistant without changing its in-memory navigation state:
    /// the current conversation, New Chat, and Archive are all left untouched.
    func selectAssistant() {
        selectedDestination = .assistant
    }

    func selectAssistant(_ id: ConversationModel.ID) {
        isAssistantArchivePresented = false
        assistantLibrary.select(id)
        selectedDestination = .assistant
    }

    func openSettings(route: SettingsRoute = .index) {
        if selectedDestination != .settings {
            settingsReturnDestination = selectedDestination
        }
        settingsRoute = route
        selectedDestination = .settings
    }

    func closeSettings() {
        let destination = settingsReturnDestination
        settingsRoute = .index
        switch destination {
        case .workspace(let id):
            if workspaces.contains(where: { $0.id == id }) {
                select(id)
            } else {
                selectVault()
            }
        case .vault:
            selectVault()
        case .assistant:
            selectAssistant()
        case .metrics:
            selectedDestination = .metrics
        case .settings:
            selectVault()
        }
    }

    func navigateBackInSettings() {
        guard selectedDestination == .settings else { return }
        if let parent = settingsRoute.parent {
            settingsRoute = parent
        } else {
            closeSettings()
        }
    }

    /// Promotes a compact Sidebar preview into the main Assistant surface while
    /// keeping the conversation navigator visible in the shared Sidebar.
    func openAssistantFullScreen(_ id: ConversationModel.ID? = nil) {
        sidebarMode = .assistant
        if let id {
            selectAssistant(id)
        } else {
            _ = openNewAssistantChat()
        }
    }

    func showAssistantArchive() {
        isAssistantArchivePresented = true
        selectedDestination = .assistant
    }

    var sidebarAssistantConversation: ConversationModel? {
        guard let id = sidebar.assistantConversationID else { return nil }
        return assistantLibrary.conversation(id: id)
    }

    func openAssistantInSidebar(_ id: ConversationModel.ID) {
        guard assistantLibrary.conversation(id: id) != nil else { return }
        sidebar.isAssistantArchivePresented = false
        sidebar.assistantConversationID = id
        refreshSessionContext()
    }

    func closeAssistantInSidebar() {
        sidebar.isAssistantArchivePresented = false
        sidebar.assistantConversationID = nil
        refreshSessionContext()
    }

    func showAssistantArchiveInSidebar() {
        sidebar.assistantConversationID = nil
        sidebar.isAssistantArchivePresented = true
        refreshSessionContext()
    }

    func deleteAssistantConversation(_ id: ConversationModel.ID) {
        if let assistantCommands {
            assistantCommands.delete(id)
            return
        }
        transcriptCache.removeConversation(id)
        let wasArchived = assistantLibrary.conversation(id: id)?.isArchived == true
        let wasSelected = assistantLibrary.selectedConversationID == id
        assistantLibrary.delete(id)
        if wasArchived, wasSelected { isAssistantArchivePresented = true }
        if sidebar.assistantConversationID == id {
            sidebar.assistantConversationID = nil
            if wasArchived { sidebar.isAssistantArchivePresented = true }
        }
    }

    func toggleAssistantPin(_ id: ConversationModel.ID) {
        if let assistantCommands {
            assistantCommands.togglePin(id)
        } else if let conversation = assistantLibrary.conversation(id: id),
            !conversation.isArchived
        {
            let toPinned = !conversation.isPinned
            let nextID =
                (toPinned
                ? assistantLibrary.pinnedConversations
                : assistantLibrary.activeConversations).first?.id
            moveAssistantConversation(id, toPinned: toPinned, before: nextID)
        }
    }
    func moveAssistantConversation(
        _ id: ConversationModel.ID,
        toPinned: Bool,
        before nextID: ConversationModel.ID?
    ) {
        if let assistantCommands {
            assistantCommands.move(id, toPinned, nextID)
        } else if let updates = assistantLibrary.orderUpdates(
            moving: id, toPinned: toPinned, before: nextID
        ) {
            assistantLibrary.applyOrder(updates)
        }
    }
    func renameAssistantConversation(_ id: ConversationModel.ID, to title: String) {
        if let assistantCommands {
            assistantCommands.rename(id, title)
        } else {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                assistantLibrary.conversation(id: id)?.customTitle = String(value.prefix(80))
            }
        }
    }
    func setAssistantArchived(_ id: ConversationModel.ID, archived: Bool) {
        if let assistantCommands {
            assistantCommands.archive(id, archived)
        } else if let conversation = assistantLibrary.conversation(id: id),
            !conversation.isStreaming, !conversation.isCompacting
        {
            conversation.archivedAt = archived ? .now : nil
            if archived { conversation.isPinned = false }
            if archived { assistantConversationWasArchived(id) }
        }
    }

    /// An archived conversation leaves every live-chat surface that was showing
    /// it. Keeping its id selected would strand the window on a read-only chat
    /// that has just disappeared from the ordinary navigator.
    func assistantConversationWasArchived(_ id: ConversationModel.ID) {
        if assistantLibrary.selectedConversationID == id {
            assistantLibrary.selectNewConversation()
        }
        if sidebar.assistantConversationID == id {
            sidebar.assistantConversationID = nil
            sidebar.isAssistantArchivePresented = false
        }
    }
    func forkAssistantConversation(
        _ id: ConversationModel.ID, at messageID: UUID, inSidebar: Bool = false
    ) {
        assistantCommands?.fork(id, messageID, inSidebar)
    }
    func editAssistantUserMessage(
        _ id: ConversationModel.ID, messageID: UUID, text: String,
        context: SessionContext = .none, includesTerminalSuggestion: Bool = false
    ) {
        assistantCommands?.edit(id, messageID, text, context, includesTerminalSuggestion)
    }

    @discardableResult
    func sendAssistantSidebarDraft() -> ConversationModel? {
        let draft = sidebar.assistantDraft
        guard let conversation = assistantLibrary.startConversation(draft) else { return nil }
        sidebar.assistantConversationID = conversation.id
        sidebar.assistantDraft = ConversationModel()
        return conversation
    }

    /// Republishes the focused Workspace's host, directory, and OS facts for the
    /// sidebar composer.
    ///
    /// It writes to the column, not to a conversation. Stamping this onto
    /// whichever chat the sidebar happened to be showing meant the chat kept it:
    /// send from the sidebar, open the same conversation in the Assistant workspace,
    /// and a host and directory that workspace knows nothing about were still on
    /// display — and would still have been uploaded.
    ///
    /// No Workspace selected clears it rather than returning early. Leaving the
    /// last value in place froze a host and directory the user had navigated
    /// away from.
    func refreshSessionContext() {
        guard let workspace = selectedWorkspace, let hostStore else {
            sidebar.sessionContext = .none
            return
        }
        sidebar.sessionContext = SessionContext(
            hostID: workspace.focusedPane.hostID,
            hostName: workspace.focusedPane.hostID.flatMap { hostStore.host($0)?.name },
            workingDirectory: workspace.focusedPane.workingDirectory,
            workingDirectoryDisplayLabel: workspace.focusedPane.displayedWorkingDirectory,
            showsWorkingDirectoryChip: workspace.focusedPane.displayedWorkingDirectory != nil,
            systemInfo: workspace.focusedPane.remoteSystemInfo
        )
    }

    /// Selects a dynamic Workspace by its order in the Navigator.
    func select(index: Int) {
        guard workspaces.indices.contains(index) else { return }
        select(workspaces[index].id)
    }

    func selectNext() {
        guard !workspaces.isEmpty else { return }
        guard let selectedWorkspaceID,
            let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID })
        else {
            select(workspaces[0].id)
            return
        }
        select(workspaces[(index + 1) % workspaces.count].id)
    }

    func selectPrevious() {
        guard !workspaces.isEmpty else { return }
        guard let selectedWorkspaceID,
            let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID })
        else {
            select(workspaces[workspaces.count - 1].id)
            return
        }
        select(workspaces[(index - 1 + workspaces.count) % workspaces.count].id)
    }

    // MARK: - Opening

    @discardableResult
    func open(
        _ workspace: Workspace,
        select shouldSelect: Bool = true
    ) -> Workspace {
        workspace.lifecycleRouter = self
        if let connectionCoordinator {
            workspace.configureConnections(using: connectionCoordinator)
        }
        if let commandHistoryStore {
            workspace.configureCommandHistory(using: commandHistoryStore)
        }
        if let sftpHistoryStore {
            workspace.configureSFTPHistory(using: sftpHistoryStore)
        }
        workspaces.append(workspace)
        if shouldSelect { select(workspace.id) }
        return workspace
    }

    /// Opens a route inside the pinned Vault workspace.
    func openPage(_ page: VaultPage) {
        vaultDestination = VaultDestination(page: page)
        vaultWorkRoute = nil
        selectedDestination = .vault
    }

    func openVaultWork(_ route: VaultWorkRoute, on page: VaultPage) {
        vaultDestination = VaultDestination(page: page)
        vaultWorkRoute = route
        selectedDestination = .vault
    }

    func closeVaultWork() {
        vaultWorkRoute = nil
    }

    @discardableResult
    func openSSHSession(
        host: Host,
        usernameHint: String? = nil,
        connectionRoute: SSHConnectionRoute? = nil,
        initialPath: String? = nil,
        placement: SessionOpenPlacement = .newWorkspace
    ) -> Workspace {
        let pane = Pane.sshSession(
            host: host,
            usernameHint: usernameHint,
            initialCommand: initialPath.flatMap(RemoteShellCommand.changeDirectory),
            recordsInitialCommandInHistory: initialPath == nil
        )
        pane.sshSession?.connectionRoute = connectionRoute
        numberPane(pane)

        if placement == .currentWorkspace,
            let workspace = selectedWorkspace,
            workspace.focusedPane.sftpChannel != nil
        {
            workspace.splitFocusedPane(axis: .horizontal, with: pane)
            return workspace
        }

        return open(Workspace(pane: pane))
    }

    /// Batch Startup opens every host as a pane of one new Workspace, tiled into a grid.
    ///
    /// Returns nil for a target that cannot be a Workspace pane — only SSH and
    /// SFTP channels can, which is the same rule `PaneKind.isCombinable`
    /// enforces everywhere else.
    @discardableResult
    func openWorkspace(_ hosts: [Host], as target: HostOpenTarget) -> Workspace? {
        let panes: [Pane] = hosts.compactMap { host in
            switch target {
            case .sshSession: .sshSession(host: host)
            case .sftpChannel: .sftpChannel(host: host)
            }
        }
        guard let first = panes.first, let layout = SplitNode.tiled(panes) else { return nil }

        let workspace = Workspace(pane: first)
        workspace.layout = layout
        workspace.focusedPaneID = first.id
        open(workspace)

        // After the append, not before: `numberPane` reads the indices of panes
        // already in `workspaces`, and one that is not there yet is invisible to it.
        // Numbering the batch against itself is safe because ticked hosts are
        // distinct, so the same-host filter excludes every sibling — what it
        // does catch is a pane already open on one of these machines.
        panes.forEach(numberPane)
        return workspace
    }

    /// Opens every target of one Snippet as visible SSH panes. SSH session and
    /// Workspace titles keep their ordinary host-derived defaults; each pane
    /// submits the same command independently after login.
    @discardableResult
    func openSnippetWorkspace(hosts: [Host], command: String) -> Workspace? {
        let panes = hosts.map { Pane.sshSession(host: $0, initialCommand: command) }
        guard let first = panes.first, let layout = SplitNode.tiled(panes) else { return nil }

        let workspace = Workspace(pane: first)
        workspace.layout = layout
        workspace.focusedPaneID = first.id
        open(workspace)
        panes.forEach(numberPane)
        return workspace
    }

    @discardableResult
    func openNewAssistantChat() -> ConversationModel {
        isAssistantArchivePresented = false
        let conversation = assistantLibrary.selectNewConversation()
        selectedDestination = .assistant
        return conversation
    }

    /// One machine's SFTP browser, listed in the sidebar under "Sessions".
    ///
    /// A caller with a terminal working directory can override the host's saved
    /// initial path for this browser only. Opening in the current Workspace is
    /// an explicit layout choice and always places the browser to the right of
    /// the focused shell.
    @discardableResult
    func openSFTPChannel(
        host: Host,
        initialPath: String? = nil,
        placement: SessionOpenPlacement = .newWorkspace
    ) -> Workspace {
        let pane = Pane.sftpChannel(host: host, initialPath: initialPath)
        numberPane(pane)
        if let connectionCoordinator { pane.configureConnections(using: connectionCoordinator) }
        if let sftpHistoryStore { pane.configureSFTPHistory(using: sftpHistoryStore) }

        if placement == .currentWorkspace,
            let workspace = selectedWorkspace,
            workspace.focusedPane.sshSession != nil
        {
            workspace.splitFocusedPane(axis: .horizontal, with: pane)
            return workspace
        }

        return open(Workspace(pane: pane))
    }

    @discardableResult
    func openSerialSession(
        configuration: SerialConnectionConfiguration,
        service: any SerialPortServing
    ) -> Workspace {
        open(Workspace(pane: .serialSession(configuration: configuration, service: service)))
    }

    /// Opens the host editor, reusing the workspace that already holds one for the
    /// same host — and the same initial group counts as the same new Host form.
    /// The same reasoning as `openPage`: a half-typed form is easier to find
    /// again than to tell apart from another empty copy.
    func openHostEditor(host: Host?, groupID: HostGroup.ID? = nil) {
        openVaultWork(
            .hostEditor(host?.id, groupID: host == nil ? groupID : nil),
            on: .hosts
        )
    }

    // MARK: - Combining

    /// Folds every pane of `source` into `target` beside a named pane, on a named
    /// side, and closes the source workspace.
    ///
    /// The one merge gesture in the app: drag a workspace out of the strip and drop it
    /// on the edge of a pane. Which edge you let go over is which side the panes
    /// land on, so the preview rectangle and the result are the same shape. The
    /// workspace strip itself merges nothing — a workspace dropped there reorders, and a pane
    /// dropped there becomes its own workspace.
    ///
    /// A Workspace is built only from things already open. There used to be a
    /// "Connect in Split" that welded a host you had never opened onto whatever
    /// workspace happened to be front; combining is a rearrangement of what is on
    /// screen, and nothing connects as a side effect of a layout change.
    ///
    /// The source's own thread goes with it. A Workspace has one thread of its
    /// own, and silently keeping the wrong one is worse than continuing the
    /// survivor's — which is the one still in front of you. A *chat pane's*
    /// thread is not the workspace's and travels with the pane, so folding a chat into
    /// a Workspace brings its conversation along intact.
    func merge(
        _ source: Workspace.ID,
        into target: Workspace.ID,
        beside paneID: Pane.ID,
        axis: SplitAxis,
        side: SplitSide
    ) {
        guard source != target,
            let sourceWorkspace = workspaces.first(where: { $0.id == source }),
            let targetWorkspace = workspaces.first(where: { $0.id == target }),
            sourceWorkspace.isCombinable,
            let targetPane = targetWorkspace.layout.pane(paneID),
            targetPane.isCombinable
        else { return }
        targetWorkspace.layout = targetWorkspace.layout.splitting(
            paneID,
            axis: axis,
            side: side,
            with: sourceWorkspace.layout
        )
        targetWorkspace.focusedPaneID = sourceWorkspace.layout.firstPane.id
        workspaces.removeAll { $0.id == source }
        select(target)
    }

    /// The same fold, into a specific empty slot rather than beside the focused
    /// pane — what dropping onto an `EmptyPaneView` does.
    func fill(_ slot: Pane.ID, in target: Workspace.ID, withPanesOf source: Workspace.ID) {
        guard source != target,
            let sourceWorkspace = workspaces.first(where: { $0.id == source }),
            let targetWorkspace = workspaces.first(where: { $0.id == target }),
            sourceWorkspace.isCombinable,
            targetWorkspace.layout.pane(slot)?.isEmptySlot == true
        else { return }
        targetWorkspace.replacePane(slot, with: sourceWorkspace.layout)
        workspaces.removeAll { $0.id == source }
        select(target)
    }

    // MARK: - Rearranging panes

    /// Moves one pane beside another, inside the Workspace they share.
    ///
    /// Panes do not cross Workspaces. Getting a pane into a different one is two
    /// deliberate moves — drop it on the workspace strip so it becomes a workspace, then drag
    /// that workspace into the target's pane area — rather than one gesture a few
    /// pixels from a gesture that means something else. `PaneView.acceptsDrop`
    /// enforces the same-Workspace rule at the other end.
    ///
    /// Lifted out before it is placed. That is safe because the target is never
    /// the pane being moved (the caller's own guard), so it always survives the
    /// removal — and doing it in this order means the pane is never in the tree
    /// twice, which matters because both copies would share one id and `removing`
    /// would take out the wrong one.
    ///
    /// Closes the source workspace when the move emptied it.
    func movePane(_ paneID: Pane.ID, beside target: Pane.ID, axis: SplitAxis, side: SplitSide) {
        guard paneID != target, let pane = pane(paneID) else { return }
        detach(paneID)
        guard let targetWorkspace = workspace(holding: target) else { return }
        targetWorkspace.layout = targetWorkspace.layout.splitting(
            target, axis: axis, side: side, with: pane
        )
        targetWorkspace.focusedPaneID = paneID
        select(targetWorkspace.id)
    }

    /// The same move, into an unfilled slot, which the pane replaces.
    func movePane(_ paneID: Pane.ID, into slot: Pane.ID) {
        guard paneID != slot, let pane = pane(paneID) else { return }
        detach(paneID)
        guard let targetWorkspace = workspace(holding: slot) else { return }
        targetWorkspace.layout = targetWorkspace.layout.replacing(slot, with: .leaf(pane))
        targetWorkspace.focusedPaneID = paneID
        select(targetWorkspace.id)
    }

    /// Lifts a pane out into a workspace of its own at `index`, or at the end of the
    /// strip when there is none.
    ///
    /// What dropping a pane on the workspace strip does — anywhere on it. The strip
    /// takes a pane to mean one thing only, so there is no zone to aim for and no
    /// second outcome a few pixels away.
    ///
    /// The inverse of `merge`: a Workspace can be taken apart the way it was put
    /// together. The new workspace gets its own conversation — the thread stays with
    /// the Workspace that held it, the same choice `duplicateSelectedInNewWorkspace`
    /// makes, because carrying it along would hand one thread's context to two
    /// workspaces that no longer share a screen.
    ///
    /// A no-op for a pane that is already alone in its workspace: there is nothing to
    /// detach it from, and doing it anyway would be a reorder wearing the wrong
    /// name. That also means the lift never removes a workspace, so an index worked out
    /// before the call is still the right one after it.
    @discardableResult
    func detachPane(_ paneID: Pane.ID, at index: Int? = nil) -> Workspace? {
        guard let pane = pane(paneID),
            let source = workspace(holding: paneID),
            source.panes.count > 1
        else { return nil }
        detach(paneID)

        let workspace = Workspace(pane: pane)
        workspace.lifecycleRouter = self
        workspaces.insert(workspace, at: min(index ?? workspaces.count, workspaces.count))
        select(workspace.id)
        return workspace
    }

    /// The inverse of `merge`: every pane of a split Workspace becomes a
    /// Workspace of its own.
    ///
    /// A Workspace is built by folding things together, so it has to be possible
    /// to take one back apart in a single move — otherwise undoing a merge means
    /// dragging each pane out to the Navigator one at a time, and the last one
    /// cannot be dragged out at all.
    ///
    /// The panes keep their layout order, and the first stays in the original
    /// Workspace so the row you right-clicked is still there afterwards. The
    /// sessions are untouched: this is a rearrangement, and nothing disconnects.
    func separatePanes(in id: Workspace.ID) {
        guard let source = workspaces.first(where: { $0.id == id }), source.isSplit,
            let index = workspaces.firstIndex(where: { $0.id == id })
        else { return }

        // Front to back, each inserted just after the one before it. Detaching
        // never removes the source — `detachPane` refuses a pane that is already
        // alone — so this index stays correct for the whole run.
        for (offset, pane) in source.panes.dropFirst().enumerated() {
            detachPane(pane.id, at: index + 1 + offset)
        }
        select(id)
    }

    /// Takes a pane out of whatever holds it, closing that workspace if it was the
    /// last one there.
    private func detach(_ paneID: Pane.ID) {
        guard let workspace = workspace(holding: paneID) else { return }
        if !workspace.closePane(paneID) {
            removeWorkspaceForMove(workspace.id)
        }
    }

    /// Removes an emptied source workspace while its pane is being moved. This is not
    /// a close: the same live session is about to be inserted elsewhere.
    private func removeWorkspaceForMove(_ id: Workspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces.remove(at: index)
        if selectedWorkspaceID == id {
            selectedDestination =
                workspaces.indices.contains(index)
                ? .workspace(workspaces[index].id)
                : workspaces.last.map { .workspace($0.id) } ?? .vault
        }
    }

    func pane(_ id: Pane.ID) -> Pane? {
        workspaces.lazy.compactMap { $0.layout.pane(id) }.first
    }

    func workspace(holding paneID: Pane.ID) -> Workspace? {
        workspaces.first { $0.layout.pane(paneID) != nil }
    }

    // MARK: - Splitting and duplicating

    /// Whether Split and Duplicate have anything to act on.
    ///
    /// Both come down to the same question — is the focused pane something that
    /// belongs in a Workspace — so both read the same predicate. Carving a slot
    /// beside a manager page, or a second copy of a hole, are results nobody
    /// asked for; better a disabled menu item than a command that quietly does
    /// nothing. See `PaneKind.isCombinable`.
    var canSplitSelected: Bool {
        selectedWorkspace?.focusedPane.isCombinable ?? false
    }

    var canDuplicateSelected: Bool {
        guard canSplitSelected, let workspace = selectedWorkspace else { return false }
        return !workspace.panes.contains { $0.serialSession != nil }
    }

    /// Carves an empty slot beside the focused pane, for something already open
    /// to be dragged into. Deliberately not a connection: choosing a layout and
    /// choosing a machine are two decisions, and only one of them was asked for.
    func splitSelected(axis: SplitAxis) {
        guard let workspace = selectedWorkspace, canSplitSelected else { return }
        workspace.splitFocusedPane(axis: axis, with: Pane(.empty))
    }

    /// Copies the focused pane beside itself, keeping its kind — a second shell
    /// on the same host, a second browser on the same machine.
    func duplicateSelected(axis: SplitAxis) {
        guard let workspace = selectedWorkspace, let copy = copyOfFocusedPane() else { return }
        workspace.splitFocusedPane(axis: axis, with: copy)
    }

    /// The same copy, in a workspace of its own — for when the second shell is a
    /// separate job rather than something to watch side by side.
    ///
    /// Pane-level, and named so, because the sidebar's rows are panes: "Duplicate
    /// in New Workspace" on a row that names one shell has to mean that shell, even
    /// when it lives in a Workspace with two others.
    func duplicatePaneInNewWorkspace() {
        guard let copy = copyOfFocusedPane() else { return }
        open(Workspace(pane: copy))
    }

    /// Workspace-level: a Workspace is copied whole — same layout, same divider
    /// positions, fresh panes — and anything else copies its one pane.
    ///
    /// The scope follows the surface. This is what the *workspace* menu and the menu
    /// bar call, and both of those point at a workspace; a right-click on a Workspace
    /// points at no particular pane, so duplicating whichever one the caret was
    /// last in would be a coin toss dressed as a command. `duplicatePaneInNewWorkspace`
    /// is the pane-level twin, for the sidebar.
    ///
    /// The copy is the arrangement and nothing else. Names do not come along —
    /// two workspaces called "prod cluster" is a collision, not a copy, the same
    /// reasoning `Pane.copy` gives — and neither does `broadcastsInput`: a
    /// duplicate that arrived already broadcasting would send the first thing
    /// typed into it to shells nobody switched it on for.
    func duplicateSelectedInNewWorkspace() {
        guard let sourceWorkspace = selectedWorkspace else { return }
        guard sourceWorkspace.isSplit else { return duplicatePaneInNewWorkspace() }
        guard let layout = sourceWorkspace.layout.copied() else { return }

        let duplicate = Workspace(pane: layout.firstPane)
        duplicate.layout = layout
        duplicate.focusedPaneID = layout.firstPane.id
        open(duplicate)
        // After the append, for the reason `openWorkspace` gives: `numberPane`
        // reads the panes already in `workspaces`, and one that is not there yet is
        // invisible to it.
        layout.panes.forEach(numberPane)
    }

    func toggleBroadcastInput(in workspace: Workspace) {
        workspace.broadcastsInput.toggle()
    }

    /// Gives `pane` the lowest number not currently in use by a pane of the same
    /// kind on the same host, so a second shell on web-01 reads "web-01 (1)".
    ///
    /// Lowest-free rather than highest-plus-one: closing "web-01 (1)" and opening
    /// another gives that name back instead of skipping to (3), and the panes
    /// that stayed open never renumber.
    ///
    /// Scoped to same kind *and* same host. An SSH session and an SFTP channel
    /// on web-01 already have different symbols in Sessions, so numbering across
    /// them would answer a question nobody asked.
    func numberPane(_ pane: Pane) {
        guard let hostID = pane.hostID else { return }
        let taken = Set(
            panes(ofKind: pane.kind)
                .filter { $0.pane.hostID == hostID && $0.pane !== pane }
                .map(\.pane.duplicateIndex)
        )
        var index = 0
        while taken.contains(index) { index += 1 }
        pane.duplicateIndex = index
    }

    /// An unfilled slot is not something to make a second of, so this is
    /// narrower than `Pane.copy` — which does copy one, because a Workspace
    /// duplicated whole should arrive with the same hole in it.
    private func copyOfFocusedPane() -> Pane? {
        guard let source = selectedWorkspace?.focusedPane, source.isCombinable,
            let copy = source.copy()
        else { return nil }
        numberPane(copy)
        return copy
    }

    /// Moving preserves live transports and does not populate close history.
    func takeWorkspaceForMove(_ id: Workspace.ID) -> Workspace? {
        guard !isClosed, let workspace = workspaces.first(where: { $0.id == id }) else { return nil }
        removeWorkspaceForMove(id)
        workspace.lifecycleRouter = nil
        dragging = nil
        if workspaces.isEmpty {
            selectedDestination = .vault
            vaultDestination = .welcome
            vaultWorkRoute = nil
        }
        refreshSessionContext()
        reconcileSidebarMode()
        return workspace
    }

    func closeForWindow() {
        guard !isClosed else { return }
        isClosed = true
        for workspace in workspaces {
            workspace.disconnectConnections()
            workspace.lifecycleRouter = nil
        }
        workspaces.removeAll()
        reopenStack.removeAll()
        dragging = nil
        presentations.route = nil
        transcriptCache.removeAll()
        focusToolbarFindField = nil
        selectedDestination = .vault
        refreshSessionContext()
    }

    // MARK: - Closing

    func close(_ id: Workspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspaces.remove(at: index)
        removed.disconnectConnections()
        reopenStack.append(removed)
        if reopenStack.count > 10 { reopenStack.removeFirst() }

        if selectedWorkspaceID == id {
            // Select the neighbour that visually takes its place.
            if workspaces.indices.contains(index) {
                selectedDestination = .workspace(workspaces[index].id)
            } else if let neighbour = workspaces.last {
                selectedDestination = .workspace(neighbour.id)
            } else {
                promoteVisibleSidebarConversationOrSelectVault()
            }
        }
    }

    /// ⌘W: closes the focused *pane* when the workspace is split, otherwise the workspace.
    /// This matches how every split-capable terminal behaves, and is why
    /// `closePane` reports whether the workspace survived.
    func closeSelected() {
        guard let workspace = selectedWorkspace else { return }
        if workspace.isSplit {
            workspace.focusedPane.disconnectConnection()
            if !workspace.closePane(workspace.focusedPaneID) {
                close(workspace.id)
            }
        } else {
            close(workspace.id)
        }
    }

    func closeOthers(than id: Workspace.ID) {
        for workspace in workspaces where workspace.id != id {
            workspace.disconnectConnections()
            reopenStack.append(workspace)
        }
        workspaces.removeAll { $0.id != id }
        selectedWorkspaceID = id
    }

    func closeAll() {
        for workspace in workspaces { workspace.disconnectConnections() }
        reopenStack.append(contentsOf: workspaces)
        workspaces.removeAll()
        promoteVisibleSidebarConversationOrSelectVault()
    }

    private func promoteVisibleSidebarConversationOrSelectVault() {
        guard sidebarMode == .assistant,
            let conversationID = sidebar.assistantConversationID,
            assistantLibrary.conversation(id: conversationID) != nil
        else {
            selectedDestination = .vault
            return
        }
        openAssistantFullScreen(conversationID)
    }

    /// Closes one pane, and the Workspace with it when that was the last one.
    ///
    /// The sidebar's rows are panes, so its Close acts on a pane — closing the
    /// whole Workspace because you dismissed one of its three shells would take
    /// two things you did not point at.
    func closePane(_ paneID: Pane.ID) {
        guard let workspace = workspaces.first(where: { $0.layout.pane(paneID) != nil }) else { return }
        workspace.layout.pane(paneID)?.disconnectConnection()
        if !workspace.closePane(paneID) {
            close(workspace.id)
        }
    }

    func closeWorkspaces(for hostID: Host.ID) {
        let paneIDs = workspaces.flatMap(\.panes).filter { $0.hostID == hostID }.map(\.id)
        for paneID in paneIDs { closePane(paneID) }
        if case .hostEditor(let editingID, _) = vaultWorkRoute,
            editingID == hostID
        {
            closeVaultWork()
        }
    }

    func reopenLastClosed() {
        guard let workspace = reopenStack.popLast() else { return }
        workspace.prepareForReopen()
        open(workspace)
    }

    // MARK: - Reordering

    /// Drag-reorder in the Navigator: puts `id` at `index` in the Workspace
    /// list after excluding the source workspace from insertion-index geometry.
    ///
    /// Remove-then-insert rather than `move(fromOffsets:toOffset:)`. The index
    /// comes from the other visible rows; the offset form would read it as an index into
    /// the list that still contains it, and land one place short of the preview
    /// every time the workspace moved rightwards.
    func move(_ id: Workspace.ID, to index: Int) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces.remove(at: from)
        workspaces.insert(workspace, at: min(max(index, 0), workspaces.count))
    }

    /// A workspace with one pane *is* that pane, so its name lives on the pane — one
    /// store rather than two kept in step. Only a Workspace names itself,
    /// because only a Workspace is a thing separate from what it contains.
    ///
    /// Manager pages, forms and a host's tunnels refuse outright — see
    /// `Workspace.isRenameable`. The guard is here as well as in the menu so the
    /// rule is a property of the model rather than of one view remembering to
    /// ask.
    func rename(_ id: Workspace.ID, to title: String) {
        guard let workspace = workspaces.first(where: { $0.id == id }), workspace.isRenameable else { return }
        if workspace.isSplit {
            workspace.customTitle = Self.cleaned(title)
        } else {
            workspace.focusedPane.customTitle = Self.cleaned(title)
        }
    }

    /// Panes are renamed from their sidebar row. Empty clears the name rather
    /// than setting a blank one, so there is one way back to the derived title
    /// and it is the obvious one.
    func rename(pane id: Pane.ID, to title: String) {
        guard let pane = workspaces.lazy.compactMap({ $0.layout.pane(id) }).first else { return }
        pane.customTitle = Self.cleaned(title)
    }

    private static func cleaned(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension WindowModel: WorkspaceLifecycleRouting {
    func workspace(_ workspace: Workspace, closePaneAfterSSHSessionExit paneID: Pane.ID) {
        guard workspaces.contains(where: { $0 === workspace }),
            workspace.layout.pane(paneID) != nil
        else { return }
        closePane(paneID)
    }

    func workspaceContextDidChange(_ workspace: Workspace) {
        guard selectedWorkspace === workspace else { return }
        refreshSessionContext()
        reconcileSidebarMode()
    }

    func workspaceRemoteWindowTitleDidChange(_ workspace: Workspace) {
        guard selectedWorkspace === workspace else { return }
        publishRemoteWindowTitle()
    }

    private func publishRemoteWindowTitle() {
        remoteWindowTitleSink?.windowRemoteTitleDidChange(
            focusedSSHSession?.menuBarWindowTitle
        )
    }
}

// MARK: - Dragging

/// What a drag in the workspace bar or the pane area is carrying.
///
/// Two cases because the same drop target answers both: dropping a *workspace* on a
/// pane folds that whole Workspace in, while dropping a *pane* moves just that
/// one out of wherever it was.
nonisolated enum DragPayload: Hashable, Sendable {
    case workspace(UUID)
    case pane(UUID)
    case assistantConversation(UUID)

    nonisolated var isLayoutPayload: Bool {
        switch self {
        case .workspace, .pane: true
        case .assistantConversation: false
        }
    }
}

// MARK: - Sidebar rows

/// One pane, with the Workspace holding it — what a sidebar row is.
///
/// A pair rather than a back-pointer on `Pane`: a pane does not otherwise need
/// to know which workspace owns it, and a reference cycle for the sake of the sidebar
/// would be paying in the model for something the view can compute.
struct PaneRef: Identifiable {
    let pane: Pane

    var id: Pane.ID { pane.id }

}
