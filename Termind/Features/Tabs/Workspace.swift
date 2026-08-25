import Foundation

protocol WorkspaceLifecycleRouting: AnyObject {
    func workspace(_ workspace: Workspace, closePaneAfterSSHSessionExit paneID: Pane.ID)
    func workspaceContextDidChange(_ workspace: Workspace)
}

nonisolated enum CommandComposerState: Equatable, Sendable {
    case idle
    case readingDraft
    case generating
    case inserted(targetCount: Int)
    case failed(String)
}

/// One tab in the tab bar: a tree of panes.
///
/// Called a *Workspace* once it holds more than one pane, and that is the word
/// the UI uses — a shell beside its file browser is one thing you arranged, not
/// two tabs that happen to be stacked. A single-pane Workspace is just a tab and
/// names itself after what it holds.
///
/// A Workspace is built by combining things that are already open: drag a tab
/// out of the strip and drop it on the edge of a pane, or on an empty slot that
/// Split carved. That is the only merge gesture — the tab strip itself reorders
/// and detaches, and never combines. Nothing connects on your behalf as a side
/// effect of arranging a layout — see `WindowModel.merge`.
///
@Observable
final class Workspace: Identifiable {
    let id = UUID()
    var layout: SplitNode {
        didSet {
            cancelCommandComposition()
            synchronizeInputRouters(previousLayout: oldValue)
        }
    }
    var focusedPaneID: Pane.ID {
        didSet {
            guard focusedPaneID != oldValue else { return }
            cancelCommandComposition()
            lifecycleRouter?.workspaceContextDidChange(self)
        }
    }
    /// `nil` means the title tracks the focused pane.
    var customTitle: String?
    weak var lifecycleRouter: (any WorkspaceLifecycleRouting)?

    /// Whether typing into one sshSession pane types into all of them.
    ///
    /// State of the Workspace rather than of a pane, because the panes *are*
    /// the group you arranged: a per-pane opt-in would let two shells each
    /// broadcast to a different set, and then there is no answer to "who hears
    /// this". Turning it on from any header turns it on for the tab, and a pane
    /// dragged in afterwards joins — which is why the button stays visible
    /// while it is lit instead of hiding with the close button.
    var broadcastsInput: Bool = false {
        didSet {
            guard broadcastsInput != oldValue else { return }
            cancelCommandComposition()
        }
    }
    var commandComposerState: CommandComposerState = .idle
    private var commandComposerTask: Task<Void, Never>?
    private var commandComposerDismissTask: Task<Void, Never>?
    private var commandComposerGeneration: UInt64 = 0

    init(pane: Pane) {
        self.layout = .leaf(pane)
        self.focusedPaneID = pane.id
        synchronizeInputRouters()
    }

    var panes: [Pane] { layout.panes }

    var focusedPane: Pane {
        layout.pane(focusedPaneID) ?? layout.firstPane
    }

    /// Whether this tab may be combined with another — every pane in it has to
    /// be something that belongs in a Workspace. An unfilled split fails the
    /// test, so a Workspace has to be finished before it can be folded into a
    /// third one. See `PaneKind.isCombinable`.
    var isCombinable: Bool { panes.allSatisfy(\.isCombinable) }

    /// Whether a tab dragged out of the strip could be dropped *into* this one:
    /// a sshSession, a file browser, or any Workspace of them.
    ///
    /// Deliberately wider than `isCombinable`, which asks the opposite question
    /// and answers no for a half-arranged Workspace. A Workspace with an
    /// unfilled slot cannot be folded into a third tab, but it is exactly the
    /// thing you drag another tab into — `EmptyPaneView` says so in as many
    /// words.
    var acceptsMerge: Bool { panes.contains { $0.isCombinable || $0.isEmptySlot } }

    /// Whether this tab may be given a name.
    ///
    /// A Workspace always may: it is a group *you* assembled, and "Workspace" is
    /// a description rather than a name. Otherwise the tab is its one pane, so
    /// the pane's rule decides — see `PaneKind.isRenameable`.
    var isRenameable: Bool {
        isSplit || focusedPane.kind.isRenameable
    }

    var isSplit: Bool {
        if case .split = layout { return true }
        return false
    }

    var symbol: String { isSplit ? "rectangle.split.2x1" : focusedPane.symbol }

    /// Which sidebar section lists this tab, if any.
    var kind: PaneKind { focusedPane.kind }

    var status: ConnectionStatus { focusedPane.status }

    var hasUnreadOutput: Bool {
        panes.contains { $0.hasUnreadOutput }
    }

    var hostID: Host.ID? { focusedPane.hostID }

    var workingDirectory: String? { focusedPane.workingDirectory }

    /// A split tab is named for itself, not for whichever half you clicked last.
    ///
    /// Reading the focused pane meant one tab wore two names depending on where
    /// the caret was, which is no name at all. Unnamed, it says "Workspace" —
    /// the panes are listed individually in the sidebar, so the tab only has to
    /// identify the *group*.
    ///
    /// A tab with one pane *is* that pane, so it takes the pane's name and never
    /// consults `customTitle`: renaming such a tab writes through to the pane
    /// (see `WindowModel.rename`), and one thing has one name. It also means a
    /// renamed tab reads "Workspace" the moment it is split, since the name it
    /// was given went to the pane rather than to the group.
    func title(in store: HostStore) -> String {
        if isSplit { return customTitle ?? String(localized: "Workspace") }
        return focusedPane.title(in: store)
    }

    func subtitle(in store: HostStore) -> String? {
        if isSplit {
            let count = panes.count
            return String(localized: "\(count) panes")
        }
        return focusedPane.subtitle(in: store)
    }

    // MARK: - Mutation

    func focus(_ paneID: Pane.ID) {
        guard layout.pane(paneID) != nil else { return }
        focusedPaneID = paneID
    }

    /// Splits the focused pane and moves focus into the new one.
    func splitFocusedPane(axis: SplitAxis, with newPane: Pane) {
        layout = layout.splitting(focusedPaneID, axis: axis, with: newPane)
        focusedPaneID = newPane.id
    }

    /// Moves one divider. The layout is a value type, so this rebuilds the tree
    /// rather than mutating the branch where it sits.
    func setFraction(_ fraction: Double, forBranch id: UUID) {
        layout = layout.settingFraction(fraction, forBranch: id)
    }

    /// Drops a whole subtree into the slot `paneID` occupied, and focuses the
    /// first pane that arrived — dragging something into an empty split should
    /// leave you in the thing you dragged, not in the hole it filled.
    func replacePane(_ paneID: Pane.ID, with node: SplitNode) {
        guard layout.pane(paneID) != nil else { return }
        layout = layout.replacing(paneID, with: node)
        focusedPaneID = node.firstPane.id
    }

    /// Closes a pane. Returns `false` when that emptied the tab, which the
    /// window reads as "close this tab too".
    func closePane(_ paneID: Pane.ID) -> Bool {
        guard let remaining = layout.removing(paneID) else { return false }
        layout = remaining
        if layout.pane(focusedPaneID) == nil {
            focusedPaneID = remaining.firstPane.id
        }
        // The name belonged to the group; there is no group left. Keeping it
        // would hide it behind the surviving pane's name and then spring it back
        // over unrelated panes the next time this tab was split.
        if !isSplit { customTitle = nil }
        // Same reasoning, and the reason it matters more: a broadcast left set
        // on a Workspace that lost its second shell would come back live the
        // next time one was dragged in, and the first thing typed would go
        // somewhere the user never switched it on for.
        if !canBroadcast { broadcastsInput = false }
        return true
    }

    func disconnectConnections() {
        for pane in panes { pane.disconnectConnection() }
    }

    /// Preserve the tab's arrangement and conversation while replacing every
    /// dead terminal with a fresh model. TerminalPlaceholderView sees the
    /// connecting state when this Workspace is mounted again and starts the
    /// ordinary authentication / host-key / SSH connection journey.
    func prepareForReopen() {
        for pane in panes { pane.prepareForReopen() }
        synchronizeInputRouters()
    }

    func markRead() {
        for pane in panes {
            pane.sshSession?.hasUnreadOutput = false
        }
    }

    // MARK: - Broadcast

    /// The shells a broadcast reaches, in layout order.
    ///
    /// Sessions only. A file browser shares the Workspace but not the prompt —
    /// there is nothing in it for a line of shell to arrive at.
    var broadcastTargets: [SSHSessionModel] {
        panes.compactMap(\.sshSession)
    }

    /// Whether there is anything to broadcast *to*. A switch with one wire on it
    /// is a switch that does nothing, so the header hides it and the menu item
    /// disables rather than offering one.
    var canBroadcast: Bool { broadcastTargets.count > 1 }

    /// Sends text to `origin`, and to every other shell in the Workspace when
    /// broadcast is live.
    ///
    /// `canBroadcast` is read here and not only when the switch is flipped: a
    /// Workspace that has since dropped to one sshSession must deliver to the pane
    /// that asked, not to a group that no longer exists.
    func deliver(_ text: String, from origin: SSHSessionModel, submit: Bool = false) {
        let targets = broadcastsInput && canBroadcast ? broadcastTargets : [origin]
        for sshSession in targets {
            sshSession.insert(text, submit: submit)
        }
    }

    func composeFocusedCommand(using controller: any CommandComposing) {
        if commandComposerTask != nil {
            cancelCommandComposition()
            return
        }
        guard let origin = focusedPane.sshSession else { return }
        let targets = broadcastsInput && canBroadcast ? broadcastTargets : [origin]
        guard targets.allSatisfy(\.canComposeCurrentDraft) else {
            showCommandComposerFailure(
                String(
                    localized:
                        "Command Composer requires every target to be at a supported shell prompt with Shell Integration enabled."
                )
            )
            return
        }
        guard let cwd = origin.workingDirectory, !cwd.isEmpty,
            let shell = origin.integratedShell
        else {
            showCommandComposerFailure(
                String(localized: "The focused shell has not reported its current directory.")
            )
            return
        }

        commandComposerDismissTask?.cancel()
        commandComposerGeneration &+= 1
        let generation = commandComposerGeneration
        let targetIDs = targets.map(\.id)
        let revisions = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, $0.commandComposerRevision)
        })
        let focusedID = focusedPaneID
        let wasBroadcasting = broadcastsInput && canBroadcast
        commandComposerState = .readingDraft

        commandComposerTask = Task { [weak self, controller] in
            do {
                let draft = try await origin.requestCurrentDraft()
                try Task.checkCancellation()
                guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkspaceCommandComposerError.emptyDraft
                }
                guard self?.commandComposerSnapshotIsCurrent(
                    generation: generation, focusedID: focusedID,
                    wasBroadcasting: wasBroadcasting, targetIDs: targetIDs,
                    revisions: revisions
                ) == true else { throw CancellationError() }

                self?.commandComposerState = .generating
                let context = CommandComposerContext(draft: draft, shell: shell, cwd: cwd)
                let command = try await commandComposerWithTimeout {
                    try await controller.compose(context)
                }
                try Task.checkCancellation()
                guard self?.commandComposerSnapshotIsCurrent(
                    generation: generation, focusedID: focusedID,
                    wasBroadcasting: wasBroadcasting, targetIDs: targetIDs,
                    revisions: revisions
                ) == true else { throw CancellationError() }

                for target in targets {
                    target.replaceCurrentDraft(with: command)
                }
                self?.finishCommandComposition(
                    generation: generation,
                    state: .inserted(targetCount: targets.count), dismissAfter: .seconds(2)
                )
            } catch is CancellationError {
                self?.finishCancelledCommandComposition(generation: generation)
            } catch {
                self?.finishCommandComposition(
                    generation: generation,
                    state: .failed(error.localizedDescription), dismissAfter: .seconds(3)
                )
            }
        }
    }

    func cancelCommandComposition() {
        guard commandComposerTask != nil else { return }
        commandComposerGeneration &+= 1
        commandComposerTask?.cancel()
        commandComposerTask = nil
        commandComposerDismissTask?.cancel()
        commandComposerDismissTask = nil
        commandComposerState = .idle
    }

    private func commandComposerSnapshotIsCurrent(
        generation: UInt64, focusedID: Pane.ID, wasBroadcasting: Bool,
        targetIDs: [SSHSessionModel.ID], revisions: [SSHSessionModel.ID: UInt64]
    ) -> Bool {
        guard commandComposerGeneration == generation,
            focusedPaneID == focusedID,
            (broadcastsInput && canBroadcast) == wasBroadcasting
        else { return false }
        let targets = wasBroadcasting ? broadcastTargets : focusedPane.sshSession.map { [$0] } ?? []
        guard targets.map(\.id) == targetIDs else { return false }
        return targets.allSatisfy {
            $0.canComposeCurrentDraft && revisions[$0.id] == $0.commandComposerRevision
        }
    }

    private func finishCancelledCommandComposition(generation: UInt64) {
        guard commandComposerGeneration == generation else { return }
        commandComposerTask = nil
        commandComposerState = .idle
    }

    private func finishCommandComposition(
        generation: UInt64, state: CommandComposerState, dismissAfter: Duration
    ) {
        guard commandComposerGeneration == generation else { return }
        commandComposerTask = nil
        commandComposerState = state
        scheduleCommandComposerDismiss(generation: generation, after: dismissAfter)
    }

    private func showCommandComposerFailure(_ message: String) {
        commandComposerGeneration &+= 1
        commandComposerTask?.cancel()
        commandComposerTask = nil
        commandComposerDismissTask?.cancel()
        commandComposerState = .failed(message)
        scheduleCommandComposerDismiss(
            generation: commandComposerGeneration, after: .seconds(3)
        )
    }

    private func scheduleCommandComposerDismiss(generation: UInt64, after delay: Duration) {
        commandComposerDismissTask?.cancel()
        commandComposerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.commandComposerGeneration == generation else { return }
            self?.commandComposerState = .idle
            self?.commandComposerDismissTask = nil
        }
    }

    /// Keeps each session-to-Workspace relationship correct as panes are merged,
    /// detached, replaced, and tiled. Removed sessions are cleared only when
    /// this Workspace still owns their route; a destination may already have
    /// claimed them during a tree rewrite.
    private func synchronizeInputRouters(previousLayout: SplitNode? = nil) {
        let currentSessions = broadcastTargets
        let currentIDs = Set(currentSessions.map(\.id))
        let currentSFTPSessions = panes.compactMap(\.sftpSession)
        let currentSFTPIDs = Set(currentSFTPSessions.map(\.id))

        if let previousLayout {
            for sshSession in previousLayout.panes.compactMap(\.sshSession)
            where !currentIDs.contains(sshSession.id) && sshSession.inputRouter === self {
                sshSession.inputRouter = nil
            }
            for sftpSession in previousLayout.panes.compactMap(\.sftpSession)
            where !currentSFTPIDs.contains(sftpSession.id) && sftpSession.navigationRouter === self {
                sftpSession.navigationRouter = nil
            }
        }

        for sshSession in currentSessions {
            sshSession.inputRouter = self
        }
        for sftpSession in currentSFTPSessions {
            sftpSession.navigationRouter = self
        }

        if !canBroadcast { broadcastsInput = false }
    }

}

extension Workspace: SFTPSessionNavigationRouting {
    func sftpSession(_ sftpSession: SFTPSessionModel, didChangePath path: String) {
        guard focusedPane.sftpSession === sftpSession else { return }
        lifecycleRouter?.workspaceContextDidChange(self)
    }
}

extension Workspace: SSHSessionInputRouting {
    /// Copies the exact bytes Ghostty produced for a keyboard or paste action.
    /// Sending directly preserves each event's terminal encoding and avoids
    /// feeding broadcast copies back through this router.
    func routeInteractiveInput(_ data: Data, from origin: SSHSessionModel) {
        cancelCommandComposition()
        let sessions = broadcastTargets
        guard sessions.contains(where: { $0 === origin }) else {
            origin.writeInputDirectly(data)
            return
        }

        let targets = broadcastsInput && sessions.count > 1 ? sessions : [origin]
        for sshSession in targets {
            sshSession.writeInputDirectly(data)
        }
    }

    func sshSessionDidInvalidateCommandComposition(_: SSHSessionModel) {
        cancelCommandComposition()
    }

    /// A background pane may keep reporting OSC 7 while another split has
    /// focus. Only the focused shell is allowed to change the Context shown by
    /// the Assistant sidebar.
    func sshSession(
        _ sshSession: SSHSessionModel,
        didChangeWorkingDirectory workingDirectory: String?
    ) {
        guard focusedPane.sshSession === sshSession else { return }
        lifecycleRouter?.workspaceContextDidChange(self)
    }

    /// Shell EOF is a successful completion, so it closes the shell's pane.
    /// The window owns the last-pane case because removing it also removes and
    /// reselects tabs. Standalone Workspaces still handle split panes in tests
    /// and previews.
    func closeSSHSessionPane(afterExit sshSession: SSHSessionModel) {
        guard let pane = panes.first(where: { $0.sshSession === sshSession }) else { return }
        if let lifecycleRouter {
            lifecycleRouter.workspace(self, closePaneAfterSSHSessionExit: pane.id)
        } else {
            _ = closePane(pane.id)
        }
    }
}

nonisolated private enum WorkspaceCommandComposerError: LocalizedError {
    case emptyDraft

    var errorDescription: String? {
        String(localized: "Type something at the shell prompt before composing a command.")
    }
}

nonisolated private func commandComposerWithTimeout(
    _ operation: @escaping @Sendable () async throws -> String
) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw CommandComposerError.timedOut
        }
        guard let result = try await group.next() else {
            throw CommandComposerError.invalidResponse
        }
        group.cancelAll()
        return result
    }
}

// MARK: - Convenience constructors

extension Workspace {
    func configureConnections(using coordinator: RemoteConnectionCoordinator) {
        for pane in panes { pane.configureConnections(using: coordinator) }
    }

    func configureCommandHistory(using store: CommandHistoryStore) {
        for pane in panes { pane.configureCommandHistory(using: store) }
    }

    /// A host is required: there is no local terminal to open without one.
    static func sshSession(host: Host, usernameHint: String? = nil) -> Workspace {
        Workspace(pane: .sshSession(host: host, usernameHint: usernameHint))
    }

    /// A host is required, for the same reason a sshSession needs one: there is
    /// nothing to browse without a machine on the other end.
    static func sftpSession(host: Host, initialPath: String? = nil) -> Workspace {
        Workspace(pane: .sftpSession(host: host, initialPath: initialPath))
    }

}
