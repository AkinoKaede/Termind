import Foundation

enum SessionOpenPlacement: Equatable {
    case newWorkspace
    case currentWorkspace
}

/// The state of one window: its workspaces, selection, and shared left sidebar.
///
/// One of these per window rather than one per app, so two windows can hold
/// different sets of workspaces. Menu commands reach the right instance through
/// `FocusedValues.window`.
@Observable
final class WindowModel {
    var workspaces: [Workspace] = []
    /// The top-level shell has two pinned entries followed by dynamic SSH/SFTP
    /// Workspaces. This is the single source of truth for workspace selection.
    var selectedDestination: WindowDestination = .vault
    var vaultDestination: VaultDestination = .welcome
    var vaultWorkRoute: VaultWorkRoute?
    let assistantLibrary: AssistantLibraryModel
    let sidebar = WindowSidebarState()
    let presentations = WindowPresentationState()
    let dragState = WorkspaceDragState()
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
    var assistantConversationDeletionHandler: ((ConversationModel.ID) -> Void)?
    var assistantPinHandler: ((ConversationModel.ID) -> Void)?
    var assistantMoveHandler: ((ConversationModel.ID, Bool, ConversationModel.ID?) -> Void)?
    var assistantRenameHandler: ((ConversationModel.ID, String) -> Void)?
    var assistantArchiveHandler: ((ConversationModel.ID, Bool) -> Void)?
    var assistantForkHandler: ((ConversationModel.ID, UUID, Bool) -> Void)?
    var assistantEditHandler: ((ConversationModel.ID, UUID, String, SessionContext, Bool) -> Void)?
    var assistantOperationError: String?
    var hostStore: HostLibraryModel? {
        didSet { refreshSessionContext() }
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

    /// Ordered selection saved for a manager page.
    func detailSelection(for page: VaultPage) -> [ContextPanelDetailID] {
        sidebar.selection(for: page)
    }

    /// Replaces a page selection, removing duplicates and ids belonging to a
    /// different page while keeping the first occurrence of each item.
    func setDetailSelection(_ details: [ContextPanelDetailID], for page: VaultPage) {
        sidebar.setSelection(details, for: page)
    }

    func selectDetail(_ detail: ContextPanelDetailID, on page: VaultPage) {
        sidebar.select(detail, on: page)
    }

    /// Shift-click semantics: selected items retain their order; a newly added
    /// item is appended at the point the user selected it.
    func toggleDetail(_ detail: ContextPanelDetailID, on page: VaultPage) {
        sidebar.toggle(detail, on: page)
    }

    func clearDetailSelection(for page: VaultPage) {
        sidebar.clearSelection(for: page)
    }

    /// The selection that belongs to the content currently in front. Manager
    /// pages use their remembered selection; work attached to a host describes
    /// that host without overwriting the Hosts page selection.
    var activeDetailSelection: [ContextPanelDetailID] {
        if selectedDestination == .vault, let page = vaultDestination.page {
            return sidebar.selection(for: page)
        }
        return sidebar.activeDetails(for: selectedWorkspace?.focusedPane)
    }

    func clearSidebarDetailOverride() {
        sidebar.clearOverride()
    }

    /// Resolves the active ids against live store data without mutating the
    /// remembered selection. This makes deletion safe even before the next
    /// pruning pass runs.
    func activeDetailSelection(in store: HostLibraryModel) -> [ContextPanelDetailID] {
        activeDetailSelection.filter(Self.availableContextPanelDetails(in: store).contains)
    }

    /// Removes records deleted out from under a remembered selection.
    func pruneDetailSelections(in store: HostLibraryModel) {
        sidebar.pruneSelections(available: Self.availableContextPanelDetails(in: store))
    }

    func pruneDetailSelections(in store: CredentialLibraryModel) {
        let available = Set(store.keys.map { ContextPanelDetailID.key($0.id) })
            .union(store.identities.map { .identity($0.id) })
        sidebar.pruneSelections(available: available)
    }

    func pruneDetailSelections(in store: SnippetLibraryModel) {
        sidebar.pruneSelections(
            available: Set(store.snippets.map { ContextPanelDetailID.snippet($0.id) })
        )
    }

    private static func availableContextPanelDetails(in store: HostLibraryModel) -> Set<ContextPanelDetailID> {
        Set(store.hosts.map { .host($0.id) })
            .union(store.keys.map { .key($0.id) })
            .union(store.identities.map { .identity($0.id) })
            .union(store.snippets.map { .snippet($0.id) })
    }

    typealias SidebarMode = WindowSidebarState.Mode

    var showsSidebar: Bool {
        get { sidebar.isPresented }
        set { sidebar.isPresented = newValue }
    }

    var availableSidebarModes: [SidebarMode] {
        sidebar.availableModes
    }

    var sidebarMode: SidebarMode {
        get { sidebar.mode }
        set {
            guard sidebar.isModeEnabled(newValue) else { return }
            sidebar.mode = newValue
        }
    }

    func isSidebarModeEnabled(_ mode: SidebarMode) -> Bool {
        sidebar.isModeEnabled(mode)
    }

    func reconcileSidebarMode() {
        sidebar.reconcileMode()
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
        set { presentations.isQuickOpenPresented = newValue }
    }

    /// Closed workspaces, most recent last. ⇧⌘T pops from here. The Workspace retains
    /// its layout, names, and conversation, while `prepareForReopen` replaces
    /// terminal models because a dead SSH channel cannot be revived.
    private var reopenStack: [Workspace] = []

    init(
        workspaces: [Workspace] = [],
        vaultDestination: VaultDestination = .welcome,
        assistantLibrary: AssistantLibraryModel = AssistantLibraryModel()
    ) {
        self.workspaces = workspaces
        self.vaultDestination = vaultDestination
        self.assistantLibrary = assistantLibrary
        selectedDestination = workspaces.first.map { .workspace($0.id) } ?? .vault
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

    var selectedIndex: Int? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.firstIndex { $0.id == selectedWorkspaceID }
    }

    /// The only pane that application-wide find commands may touch. A Workspace
    /// can contain several terminals, so routing to "any session in the workspace"
    /// would make ⌘F search a buffer other than the one under the caret.
    var focusedSSHSession: SSHSessionModel? {
        return selectedWorkspace?.focusedPane.sshSession
    }

    var canFindInTerminal: Bool { focusedSSHSession != nil }

    var canGenerateTerminalCommand: Bool { focusedSSHSession != nil }

    func generateTerminalCommand(using controller: CommandGeneratorController) {
        selectedWorkspace?.generateFocusedCommand(using: controller)
    }

    func presentTerminalFind() {
        focusedSSHSession?.presentFind()
    }

    func navigateTerminalFind(_ direction: TerminalFindDirection) {
        focusedSSHSession?.presentFindAndNavigate(direction)
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

    var isEmpty: Bool { workspaces.isEmpty }

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
                .map { PaneRef(workspace: workspace, pane: $0) }
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
    var sftpSessionPanes: [PaneRef] { panes(ofKind: .sftpSession) }

    var sessionPanes: [PaneRef] {
        workspaces.flatMap { workspace in
            workspace.panes.compactMap { pane in
                guard pane.kind == .sshSession || pane.kind == .sftpSession else { return nil }
                return PaneRef(workspace: workspace, pane: pane)
            }
        }
    }

    var canReopen: Bool { !reopenStack.isEmpty }

    /// The most recently opened SSH session, with the workspace holding it.
    ///
    /// The Snippets page is itself the front workspace when a snippet is inserted, so
    /// "the session" cannot mean "the front workspace". Most-recent is the best
    /// answer available at P0; once sessions are real this becomes the last
    /// *focused* one.
    private var lastSSHSession: (workspace: Workspace, sshSession: SSHSessionModel)? {
        for workspace in workspaces.reversed() {
            for pane in workspace.panes.reversed() {
                if let sshSession = pane.sshSession {
                    return (workspace, sshSession)
                }
            }
        }
        return nil
    }

    var hasSSHSession: Bool { lastSSHSession != nil }

    /// Types a command onto a session's prompt and brings that workspace forward.
    ///
    /// It never sends the command — pressing Return stays the user's decision,
    /// the same rule the AI command cards follow. Returns `false` when there is
    /// no session to type into, so the caller can fall back to the pasteboard.
    ///
    /// Through `Workspace.deliver` rather than straight at the session, so a
    /// snippet inserted into a broadcasting Workspace lands in every shell in
    /// it. Every route text takes into a prompt goes through that one door.
    @discardableResult
    func insertIntoSSHSession(_ command: String) -> Bool {
        guard let (workspace, sshSession) = lastSSHSession else { return false }
        workspace.deliver(command, from: sshSession)
        select(workspace.id)
        return true
    }

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
        if let assistantConversationDeletionHandler {
            assistantConversationDeletionHandler(id)
            return
        }
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
        if let assistantPinHandler { assistantPinHandler(id) }
        else if let conversation = assistantLibrary.conversation(id: id),
            !conversation.isArchived, !conversation.isStreaming, !conversation.isCompacting
        {
            let toPinned = !conversation.isPinned
            let nextID = (toPinned
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
        if let assistantMoveHandler {
            assistantMoveHandler(id, toPinned, nextID)
        } else if let updates = assistantLibrary.orderUpdates(
            moving: id, toPinned: toPinned, before: nextID
        ) {
            assistantLibrary.applyOrder(updates)
        }
    }
    func renameAssistantConversation(_ id: ConversationModel.ID, to title: String) {
        if let assistantRenameHandler { assistantRenameHandler(id, title) }
        else {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                assistantLibrary.conversation(id: id)?.customTitle = String(value.prefix(80))
            }
        }
    }
    func setAssistantArchived(_ id: ConversationModel.ID, archived: Bool) {
        if let assistantArchiveHandler { assistantArchiveHandler(id, archived) }
        else if let conversation = assistantLibrary.conversation(id: id),
            !conversation.isStreaming, !conversation.isCompacting
        {
            conversation.archivedAt = archived ? .now : nil
            if archived { conversation.isPinned = false }
        }
    }
    func forkAssistantConversation(
        _ id: ConversationModel.ID, at messageID: UUID, inSidebar: Bool = false
    ) {
        assistantForkHandler?(id, messageID, inSidebar)
    }
    func editAssistantUserMessage(
        _ id: ConversationModel.ID, messageID: UUID, text: String,
        context: SessionContext = .none, includesTerminalSuggestion: Bool = false
    ) {
        assistantEditHandler?(id, messageID, text, context, includesTerminalSuggestion)
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
        initialPath: String? = nil,
        placement: SessionOpenPlacement = .newWorkspace
    ) -> Workspace {
        let pane = Pane.sshSession(
            host: host,
            usernameHint: usernameHint,
            initialCommand: initialPath.flatMap(Self.changeDirectoryCommand),
            recordsInitialCommandInHistory: initialPath == nil
        )
        numberPane(pane)

        if placement == .currentWorkspace,
            let workspace = selectedWorkspace,
            workspace.focusedPane.sftpSession != nil
        {
            workspace.splitFocusedPane(axis: .horizontal, with: pane)
            return workspace
        }

        return open(Workspace(pane: pane))
    }

    /// Batch Startup's second verb: every host becomes a pane of one Workspace,
    /// tiled into a grid rather than opened as a workspace each.
    ///
    /// Returns nil for a target that cannot be a Workspace pane — only SSH and
    /// SFTP sessions can, which is the same rule `PaneKind.isCombinable`
    /// enforces everywhere else.
    @discardableResult
    func openWorkspace(_ hosts: [Host], as target: HostOpenTarget) -> Workspace? {
        let panes: [Pane] = hosts.compactMap { host in
            switch target {
            case .sshSession: .sshSession(host: host)
            case .sftpSession: .sftpSession(host: host)
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
    func openSFTPSession(
        host: Host,
        initialPath: String? = nil,
        placement: SessionOpenPlacement = .newWorkspace
    ) -> Workspace {
        let pane = Pane.sftpSession(host: host, initialPath: initialPath)
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

    /// A one-shot directory change for a shell opened from an SFTP path.
    /// Single-quoting keeps spaces and shell punctuation inert; embedded
    /// apostrophes are closed, emitted literally, and reopened.
    nonisolated static func changeDirectoryCommand(for path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let quoted = path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "cd '\(quoted)'"
    }

    /// Opens the host editor, reusing the workspace that already holds one for the
    /// same host — and "no host" counts as a host here, so New Host twice means
    /// "show me the New Host form" rather than handing back a second empty copy
    /// of it. The same reasoning as `openPage`, and the same reason two of them
    /// were worth avoiding: a half-typed form is easier to find again than to
    /// tell apart from its twin in the workspace bar.
    func openHostEditor(host: Host?) {
        openVaultWork(.hostEditor(host?.id), on: .hosts)
    }

    func closeManagement() {
        closeVaultWork()
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

    var canDuplicateSelected: Bool { canSplitSelected }

    /// Whether ⌘B has a group to act on — see `Workspace.canBroadcast`.
    var canBroadcastSelected: Bool { selectedWorkspace?.canBroadcast ?? false }

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

    /// Gives `pane` the lowest number not currently in use by a pane of the same
    /// kind on the same host, so a second shell on web-01 reads "web-01 (1)".
    ///
    /// Lowest-free rather than highest-plus-one: closing "web-01 (1)" and opening
    /// another gives that name back instead of skipping to (3), and the panes
    /// that stayed open never renumber.
    ///
    /// Scoped to same kind *and* same host. An SSH session and an SFTP session
    /// on web-01 already have different symbols in Sessions, so numbering across
    /// them would answer a question nobody asked.
    private func numberPane(_ pane: Pane) {
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

    /// Closes every SSH and SFTP session pane, leaving manager pages open. No
    /// confirmation: ⇧⌘T reopens the panes, while closing them disconnects the
    /// active connections.
    func closeAllSessions() {
        for ref in sessionPanes {
            closePane(ref.pane.id)
        }
    }

    func closeWorkspaces(for hostID: Host.ID) {
        let paneIDs = workspaces.flatMap(\.panes).filter { $0.hostID == hostID }.map(\.id)
        for paneID in paneIDs { closePane(paneID) }
        if case .hostEditor(let editingID) = vaultWorkRoute,
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

    func move(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
    }

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
    let workspace: Workspace
    let pane: Pane

    var id: Pane.ID { pane.id }

    /// True when this pane shares its Workspace with others, which is when the
    /// row needs to say so — otherwise every row would carry a badge that means
    /// nothing.
    var isInWorkspace: Bool { workspace.isSplit }
}
