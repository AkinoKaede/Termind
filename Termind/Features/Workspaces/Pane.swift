import Foundation

/// What a single pane is showing.
///
/// The plan called this `WorkspaceContent`, but splitting means a workspace can hold several
/// of these at once, so the unit of content is the pane and a workspace owns a tree of
/// them. A workspace's title, icon, and status are derived from its *focused* pane.
///
enum PaneContent {
    // Work, created on demand and listed in the sidebar.
    //
    // `sftpSession` requires a host — there is no host-less SFTP session,
    // because a transfer is a conversation with one machine about one path.
    case sshSession(SSHSessionModel)
    case sftpSession(SFTPSessionModel)
    /// A slot that has been carved out and not filled yet.
    ///
    /// Split makes one of these rather than opening a connection, because
    /// choosing a layout and choosing a machine are two decisions and only one
    /// of them was asked for. What fills it has to be something already open:
    /// drag a workspace out of the strip and drop it here, or move a pane over from
    /// elsewhere in this same Workspace.
    case empty
}

/// Which sidebar section, if any, a pane belongs under.
///
/// Introduced because "everything that is not a page is a session" was wrong in
/// two directions at once: it filed the New Host form under Sessions, and it had
/// nowhere to put a conversation that is not attached to a host.
nonisolated enum PaneKind: Hashable, Sendable {
    /// A shell on a host. This is what "Session" means in the sidebar, and it
    /// means only that — a machine's tunnels used to land here too, which put a
    /// second row under Sessions for a host you already had a shell on.
    case sshSession
    /// One host's SFTP browser. It shares the Sessions section with SSH while
    /// retaining its own kind for protocol-specific actions and iconography.
    case sftpSession
    /// An unfilled split. Belongs in no sidebar section — it is a hole in a
    /// layout, and listing it would put a row in Sessions for something that is
    /// not a session yet and may never be one.
    case empty

    /// Whether a pane of this kind may share a Workspace with others.
    ///
    /// Work you do side by side: a shell, a file browser, a conversation. The
    /// chat belongs here for the reason the app exists — a conversation is
    /// *about* something, and the thing it is about is usually the pane next to
    /// it. Refusing to let those two sit together made the one arrangement this
    /// app is for the one arrangement you could not build.
    ///
    /// Management and forms live outside this type. This gates dragging,
    /// dropping, Split, Duplicate, and whether those items appear in a menu.
    ///
    /// `.empty` is not combinable, which is what stops a half-arranged Workspace
    /// from being dragged into another one before it has been filled.
    var isCombinable: Bool {
        self == .sshSession || self == .sftpSession
    }

    /// Whether a pane of this kind may be given a name.
    ///
    /// Work, and only work: a shell, a file browser, a conversation. Those are
    /// things you have several of, so which one is which is a question you can
    /// answer for yourself and nobody else can.
    ///
    /// A manager page is a destination rather than a thing you own — there is
    /// one Keychain and it is called Keychain — and renaming it would put a workspace
    /// in the bar that no longer matches the sidebar row that opens it. A form
    /// and an unfilled slot are the same story: both are named after the state
    /// they are in, and both stop existing when that state ends.
    var isRenameable: Bool {
        self == .sshSession || self == .sftpSession
    }

    /// Only work panes have transient context worth reserving a footer for.
    /// Manager pages, forms and empty slots should use the full content height
    /// instead of permanently reporting the fallback "Not connected" state.
    var showsStatusBar: Bool {
        self == .sshSession || self == .sftpSession
    }
}

/// One rectangle of content inside a workspace.
@Observable
final class Pane: Identifiable {
    let id = UUID()
    var content: PaneContent

    /// A name the user gave this pane. `nil` means the title tracks the content
    /// — the host it is on, the page it shows.
    ///
    /// Panes are nameable because a Workspace can hold three shells on one
    /// machine, and "web-01", "web-01", "web-01" in the sidebar is three rows
    /// you have to click to tell apart.
    var customTitle: String?

    /// Disambiguates panes that would otherwise read identically — the second
    /// shell on web-01 shows "web-01 (1)".
    ///
    /// An index rather than a suffix written into `customTitle`, so the name
    /// still tracks the host: rename the machine and every pane on it follows,
    /// numbers intact. Stored rather than computed from position, because
    /// closing the second of three panes must not renumber the third out from
    /// under you. `WindowModel.nextDuplicateIndex` hands them out.
    var duplicateIndex: Int = 0

    init(_ content: PaneContent) {
        self.content = content
    }

    func configureConnections(using coordinator: RemoteConnectionCoordinator) {
        switch content {
        case .sshSession(let session): session.connectionCoordinator = coordinator
        case .sftpSession(let session): session.connectionCoordinator = coordinator
        case .empty: break
        }
    }

    func configureCommandHistory(using store: CommandHistoryModel) {
        guard case .sshSession(let session) = content else { return }
        session.commandHistoryStore = store
    }

    func configureSFTPHistory(using store: SFTPHistoryModel) {
        guard case .sftpSession(let session) = content else { return }
        session.historyStore = store
    }

    var kind: PaneKind {
        switch content {
        case .sftpSession: .sftpSession
        case .sshSession: .sshSession
        case .empty: .empty
        }
    }

    /// Whether this pane may share a Workspace with others — see `PaneKind`.
    var isCombinable: Bool { kind.isCombinable }

    /// Whether this pane is an unfilled split slot, which accepts a drop by
    /// being replaced rather than split.
    var isEmptySlot: Bool {
        if case .empty = content { return true }
        return false
    }

    var symbol: String {
        switch content {
        case .sshSession: "apple.terminal"
        case .sftpSession: "folder"
        case .empty: "rectangle.dashed"
        }
    }

    /// The shell inside this pane, if it is one. Spelled once here rather than
    /// as an `if case` at each of the four places that need it.
    var sshSession: SSHSessionModel? {
        if case .sshSession(let sshSession) = content { return sshSession }
        return nil
    }

    var sftpSession: SFTPSessionModel? {
        if case .sftpSession(let sftpSession) = content { return sftpSession }
        return nil
    }

    /// Ends network state only when the pane is actually being closed. View
    /// disappearance is not ownership: dragging a pane reparents its view and
    /// must leave the same live session connected.
    func disconnectConnection() {
        switch content {
        case .sshSession(let sshSession): sshSession.disconnect()
        case .sftpSession(let sftpSession): sftpSession.disconnect()
        default: break
        }
    }

    /// Reopening a closed terminal means starting another SSH session, not
    /// remounting the model whose channel and connection task were torn down by
    /// `disconnectConnection`. Keep the Pane itself so its name, duplicate
    /// index, focus identity, and place in the split tree all survive.
    func prepareForReopen() {
        guard case .sshSession(let sshSession) = content else { return }
        sshSession.inputRouter = nil
        let replacement = sshSession.copyForReconnect()
        replacement.status = .connecting
        content = .sshSession(replacement)
    }

    var status: ConnectionStatus {
        switch content {
        case .sshSession(let sshSession): sshSession.status
        case .sftpSession(let sftpSession): sftpSession.status
        default: .disconnected
        }
    }

    var hasUnreadOutput: Bool {
        switch content {
        case .sshSession(let sshSession): sshSession.hasUnreadOutput
        default: false
        }
    }

    /// The host this pane is attached to, if any — drives the status bar and the
    /// Assistant sidebar's default context chips.
    var hostID: Host.ID? {
        switch content {
        case .sshSession(let sshSession): sshSession.hostID
        case .sftpSession(let sftpSession): sftpSession.hostID
        case .empty: nil
        }
    }

    var workingDirectory: String? {
        switch content {
        case .sshSession(let sshSession): sshSession.workingDirectory
        case .sftpSession(let sftpSession): sftpSession.path
        default: nil
        }
    }

    var displayedWorkingDirectory: String? {
        switch content {
        case .sshSession(let sshSession): sshSession.displayedWorkingDirectory
        case .sftpSession(let sftpSession): sftpSession.displayedPath
        default: nil
        }
    }

    var remoteSystemInfo: RemoteSystemInfo? {
        guard SettingsKey.isShellIntegrationEnabled else { return nil }
        guard case .sshSession(let sshSession) = content else { return nil }
        return sshSession.remoteSystemInfo
    }

    /// A fresh pane of the same kind on the same host — a second shell, a second
    /// browser, a second unfilled slot. Nil for anything a Workspace cannot
    /// hold, which is everything Duplicate is not offered on anyway.
    ///
    /// The name deliberately does not come along. Copying "logs" would give two
    /// panes both called "logs", which is exactly the collision
    /// `WindowModel.numberPane` exists to prevent — the copy takes the derived
    /// name and a number of its own.
    ///
    /// `.empty` copies as another empty slot rather than failing, so a
    /// half-arranged Workspace can still be duplicated as the half-arranged
    /// thing it is.
    func copy() -> Pane? {
        switch content {
        case .sshSession(let sshSession):
            let clone = sshSession.copyForReconnect()
            clone.status = .connecting
            return Pane(.sshSession(clone))
        case .sftpSession(let sftpSession):
            return Pane(.sftpSession(sftpSession.copyForBrowsing()))
        case .empty:
            return Pane(.empty)
        }
    }

    /// Resolved against the store so a renamed host renames its workspaces — unless
    /// the user named this pane, in which case their word wins everywhere.
    func title(in store: HostLibraryModel) -> String {
        if let customTitle { return customTitle }
        return numbered(derivedTitle(in: store))
    }

    /// The number only ever decorates a *derived* name. A name the user typed is
    /// theirs as typed — appending "(1)" to it would be arguing with them about
    /// a collision they already chose to accept.
    private func numbered(_ base: String) -> String {
        duplicateIndex > 0 ? "\(base) (\(duplicateIndex))" : base
    }

    private func derivedTitle(in store: HostLibraryModel) -> String {
        switch content {
        case .sshSession(let sshSession):
            sshSession.title
        case .sftpSession(let sftpSession):
            store.host(sftpSession.hostID)?.name ?? String(localized: "SFTP")
        case .empty:
            String(localized: "Empty")
        }
    }

    /// The title with the sidebar section's own word taken back out.
    ///
    /// SFTP and SSH panes share Sessions, with their symbols distinguishing the
    /// protocol. The row therefore keeps the host name concise and unprefixed.
    func sidebarTitle(in store: HostLibraryModel) -> String {
        if let customTitle { return customTitle }
        if case .sftpSession(let sftpSession) = content,
            let host = store.host(sftpSession.hostID)
        {
            return numbered(host.name)
        }
        return numbered(derivedTitle(in: store))
    }

    func subtitle(in store: HostLibraryModel) -> String? {
        switch content {
        case .sftpSession(let sftpSession):
            sftpSession.displayedPath
        case _ where customTitle != nil:
            // A renamed pane shows its name and nothing under it: the subtitle
            // is the derived detail, and pairing it with a name the user chose
            // reads as a correction. SFTP is the exception above: its live
            // path is navigation state, not an alternate name.
            nil
        case .sshSession(let sshSession):
            sshSession.status.isLive ? sshSession.displayedWorkingDirectory : nil
        default:
            nil
        }
    }
}

// MARK: - Convenience constructors

extension Pane {
    /// One shell on a host, already marked as connecting.
    ///
    /// Here rather than inside `Workspace.sshSession(host:)` because a session pane
    /// is now born in two places — a workspace of its own, and one cell of a batch
    /// Workspace — and a second copy of this is a second chance to forget the
    /// status flip.
    static func sshSession(
        host: Host, usernameHint: String? = nil, initialCommand: String? = nil
    ) -> Pane {
        sshSession(
            host: host, usernameHint: usernameHint, initialCommand: initialCommand,
            recordsInitialCommandInHistory: true
        )
    }

    static func sshSession(
        host: Host, usernameHint: String?, initialCommand: String?,
        recordsInitialCommandInHistory: Bool
    ) -> Pane {
        let sshSession = SSHSessionModel(
            host: host, usernameHint: usernameHint, initialCommand: initialCommand,
            recordsInitialCommandInHistory: recordsInitialCommandInHistory
        )
        sshSession.status = .connecting
        return Pane(.sshSession(sshSession))
    }

    static func sftpSession(host: Host, initialPath: String? = nil) -> Pane {
        Pane(
            .sftpSession(
                SFTPSessionModel(
                    hostID: host.id, initialPath: initialPath ?? host.sftpSessionInitialPath
                )))
    }
}

nonisolated enum SplitAxis: Hashable, Sendable {
    /// Panes sit side by side (`HSplitView`).
    case horizontal
    /// Panes stack top and bottom (`VSplitView`).
    case vertical
}

/// Which side of the target a new pane or subtree lands on.
///
/// `splitting` has always put the newcomer second, which was enough while the
/// only caller was Split. Dropping on the *leading* edge of a pane has to be able
/// to put it first, or the preview rectangle lies about where the thing will go.
nonisolated enum SplitSide: Hashable, Sendable {
    case before
    case after
}

/// A workspace's layout: a binary tree of panes.
///
/// The tree is recursive so nested splits need no model change later.
indirect enum SplitNode {
    case leaf(Pane)
    case split(Branch)

    /// One division of a Workspace: an axis, the share the first child takes,
    /// and the two subtrees.
    ///
    /// The fraction is stored here rather than left to `HSplitView`, which owned
    /// its divider position and handed leftover space to whichever child asked
    /// last. Two consequences of that we needed gone: a drop previewed as "the
    /// right half" landed at whatever width AppKit chose, and resizing the workspace
    /// grew one pane while the other stayed where it was. Reading the layout
    /// from a stored ratio makes both exact — the preview is a promise the
    /// layout keeps, and every size is recomputed proportionally on resize.
    ///
    /// `id` exists so a divider drag can write a new fraction back into a tree
    /// that is otherwise all value types.
    struct Branch: Identifiable {
        let id: UUID
        var axis: SplitAxis
        /// The first child's share of the split axis, 0…1.
        var fraction: Double
        var first: SplitNode
        var second: SplitNode

        init(
            id: UUID = UUID(),
            axis: SplitAxis,
            fraction: Double = 0.5,
            first: SplitNode,
            second: SplitNode
        ) {
            self.id = id
            self.axis = axis
            self.fraction = fraction
            self.first = first
            self.second = second
        }
    }

    /// A new split, always down the middle — which is the rectangle the drop
    /// preview drew, and the only honest starting point for one.
    static func split(axis: SplitAxis, first: SplitNode, second: SplitNode) -> SplitNode {
        .split(Branch(axis: axis, first: first, second: second))
    }

    /// Tiles panes into a balanced grid: halve the list, and turn the axis a
    /// quarter each level down. Two panes sit side by side, three are one on the
    /// left and two stacked on the right, four make a 2×2.
    ///
    /// The fraction is each side's *share of the panes* rather than a flat half,
    /// which is what makes every leaf come out the same area — with three, a flat
    /// half would give the lone pane half the window and the pair a quarter each.
    ///
    /// A row of N columns was the alternative and is unusable past a handful:
    /// `Metrics.Split.minPaneLength` is 160pt, so a default window runs out of
    /// room at seven, and seven terminals in a row is not something anyone reads.
    static func tiled(_ panes: [Pane], axis: SplitAxis = .horizontal) -> SplitNode? {
        guard let only = panes.first else { return nil }
        guard panes.count > 1 else { return .leaf(only) }

        let cut = panes.count / 2
        let head = Array(panes[..<cut])
        let tail = Array(panes[cut...])
        let next: SplitAxis = axis == .horizontal ? .vertical : .horizontal
        guard let first = tiled(head, axis: next), let second = tiled(tail, axis: next) else {
            return .leaf(only)
        }
        return .split(
            Branch(
                axis: axis,
                fraction: Double(head.count) / Double(panes.count),
                first: first,
                second: second
            )
        )
    }

    var panes: [Pane] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(let branch): branch.first.panes + branch.second.panes
        }
    }

    /// The same tree with new panes in it: shape, axes and fractions preserved,
    /// every leaf replaced by `Pane.copy()`. Nil if any leaf refuses to copy.
    ///
    /// Fractions come along because they *are* the arrangement — a duplicate
    /// that resets every divider to the middle is not the Workspace you asked to
    /// duplicate. Branch ids do not: they exist so a divider drag can find the
    /// branch it grabbed, and two trees answering to one id is the kind of thing
    /// that works right up until it does not.
    func copied() -> SplitNode? {
        switch self {
        case .leaf(let pane):
            return pane.copy().map(SplitNode.leaf)
        case .split(let branch):
            guard let first = branch.first.copied(), let second = branch.second.copied() else {
                return nil
            }
            return .split(
                Branch(
                    axis: branch.axis,
                    fraction: branch.fraction,
                    first: first,
                    second: second
                )
            )
        }
    }

    var firstPane: Pane {
        switch self {
        case .leaf(let pane): pane
        case .split(let branch): branch.first.firstPane
        }
    }

    func pane(_ id: Pane.ID) -> Pane? {
        panes.first { $0.id == id }
    }

    /// Rewrites one branch's fraction. The tree is a value, so a divider drag
    /// has to rebuild the path down to the branch it moved rather than mutating
    /// it where it sits.
    func settingFraction(_ fraction: Double, forBranch id: UUID) -> SplitNode {
        guard case .split(var branch) = self else { return self }
        if branch.id == id {
            branch.fraction = fraction
        } else {
            branch.first = branch.first.settingFraction(fraction, forBranch: id)
            branch.second = branch.second.settingFraction(fraction, forBranch: id)
        }
        return .split(branch)
    }

    /// Replaces the leaf holding `paneID` with a split containing it and `newPane`.
    func splitting(
        _ paneID: Pane.ID,
        axis: SplitAxis,
        side: SplitSide = .after,
        with newPane: Pane
    ) -> SplitNode {
        splitting(paneID, axis: axis, side: side, with: .leaf(newPane))
    }

    /// The same, with a whole subtree on the new side — a merge folds another
    /// Workspace's entire layout in, not just one of its panes.
    func splitting(
        _ paneID: Pane.ID,
        axis: SplitAxis,
        side: SplitSide = .after,
        with node: SplitNode
    ) -> SplitNode {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return self }
            return switch side {
            case .after: .split(axis: axis, first: .leaf(pane), second: node)
            case .before: .split(axis: axis, first: node, second: .leaf(pane))
            }
        case .split(var branch):
            branch.first = branch.first.splitting(paneID, axis: axis, side: side, with: node)
            branch.second = branch.second.splitting(paneID, axis: axis, side: side, with: node)
            return .split(branch)
        }
    }

    /// Swaps the leaf holding `paneID` for a whole subtree — how a dragged
    /// Workspace's panes land in an empty slot. The inverse of `splitting`,
    /// which only ever inserts one pane.
    func replacing(_ paneID: Pane.ID, with node: SplitNode) -> SplitNode {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? node : self
        case .split(var branch):
            branch.first = branch.first.replacing(paneID, with: node)
            branch.second = branch.second.replacing(paneID, with: node)
            return .split(branch)
        }
    }

    /// Removes a pane, collapsing the split that held it. Returns `nil` when the
    /// tree becomes empty, which is the caller's signal to close the workspace.
    func removing(_ paneID: Pane.ID) -> SplitNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self
        case .split(var branch):
            switch (branch.first.removing(paneID), branch.second.removing(paneID)) {
            case (nil, nil):
                return nil
            case (let remaining?, nil), (nil, let remaining?):
                // The surviving side takes the whole space, so the branch — and
                // the fraction the user set on it — goes with the pane that left.
                return remaining
            case (let a?, let b?):
                branch.first = a
                branch.second = b
                return .split(branch)
            }
        }
    }
}
