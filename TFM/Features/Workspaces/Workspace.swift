import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

protocol WorkspaceLifecycleRouting: AnyObject {
    func workspace(_ workspace: Workspace, closePaneAfterSSHSessionExit paneID: Pane.ID)
    func workspaceContextDidChange(_ workspace: Workspace)
    func workspaceRemoteWindowTitleDidChange(_ workspace: Workspace)
}

/// One workspace in the workspace bar: a tree of panes.
///
/// Called a *Workspace* once it holds more than one pane, and that is the word
/// the UI uses — a shell beside its file browser is one thing you arranged, not
/// two workspaces that happen to be stacked. A single-pane Workspace is just a workspace and
/// names itself after what it holds.
///
/// A Workspace is built by combining things that are already open: drag a workspace
/// out of the strip and drop it on the edge of a pane, or on an empty slot that
/// Split carved. That is the only merge gesture — the workspace strip itself reorders
/// and detaches, and never combines. Nothing connects on your behalf as a side
/// effect of arranging a layout — see `WindowModel.merge`.
///
@Observable
final class Workspace: Identifiable {
    let id = UUID()
    var sourceTemplateID: WorkspaceTemplate.ID?
    var layout: SplitNode {
        didSet {
            cancelCommandGeneration()
            synchronizeInputRouters(previousLayout: oldValue)
        }
    }
    var focusedPaneID: Pane.ID {
        didSet {
            guard focusedPaneID != oldValue else { return }
            cancelCommandGeneration()
            lifecycleRouter?.workspaceContextDidChange(self)
            lifecycleRouter?.workspaceRemoteWindowTitleDidChange(self)
        }
    }
    /// `nil` means the title tracks the focused pane.
    var customTitle: String?
    /// The complete name assigned when this became a top-level Workspace.
    /// Keeping the rendered string rather than a counter makes future allocation
    /// depend only on the names the user can actually see.
    var automaticTitle: String?
    weak var lifecycleRouter: (any WorkspaceLifecycleRouting)?

    /// Whether typing into one sshSession pane types into all of them.
    ///
    /// State of the Workspace rather than of a pane, because the panes *are*
    /// the group you arranged: a per-pane opt-in would let two shells each
    /// broadcast to a different set, and then there is no answer to "who hears
    /// this". Turning it on from any header turns it on for the workspace, and a pane
    /// dragged in afterwards joins — which is why the button stays visible
    /// while it is lit instead of hiding with the close button.
    var broadcastsInput: Bool = false {
        didSet {
            guard broadcastsInput != oldValue else { return }
            cancelCommandGeneration()
        }
    }
    var commandGeneratorState: CommandGeneratorState {
        get { commandGeneration.state }
        set { commandGeneration.replaceStateForPresentation(newValue) }
    }
    private let commandGeneration = CommandGenerationCoordinator()

    init(pane: Pane) {
        self.layout = .leaf(pane)
        self.focusedPaneID = pane.id
        synchronizeInputRouters()
    }

    var panes: [Pane] { layout.panes }

    var focusedPane: Pane {
        layout.pane(focusedPaneID) ?? layout.firstPane
    }

    /// Whether this workspace may be combined with another — every pane in it has to
    /// be something that belongs in a Workspace. An unfilled split fails the
    /// test, so a Workspace has to be finished before it can be folded into a
    /// third one. See `PaneKind.isCombinable`.
    var isCombinable: Bool { panes.allSatisfy(\.isCombinable) }

    /// Whether a workspace dragged out of the strip could be dropped *into* this one:
    /// a sshSession, a file browser, or any Workspace of them.
    ///
    /// Deliberately wider than `isCombinable`, which asks the opposite question
    /// and answers no for a half-arranged Workspace. A Workspace with an
    /// unfilled slot cannot be folded into a third workspace, but it is exactly the
    /// thing you drag another workspace into — `EmptyPaneView` says so in as many
    /// words.
    var acceptsMerge: Bool { panes.contains { $0.isCombinable || $0.isEmptySlot } }

    /// Whether this workspace may be given a name.
    ///
    /// A Workspace always may: it is a group *you* assembled, and "Workspace" is
    /// a description rather than a name. Otherwise the workspace is its one pane, so
    /// the pane's rule decides — see `PaneKind.isRenameable`.
    var isRenameable: Bool {
        isSplit || focusedPane.kind.isRenameable
    }

    var isSplit: Bool {
        if case .split = layout { return true }
        return false
    }

    var symbol: String { isSplit ? "rectangle.split.2x1" : focusedPane.symbol }

    var status: ConnectionStatus { focusedPane.status }

    var hasUnreadCommandCompletion: Bool { panes.contains { $0.commandMonitor?.hasUnreadCompletion == true } }

    func markCommandsRead() {
        for pane in panes { pane.commandMonitor?.markRead() }
    }

    var hasUnreadOutput: Bool {
        panes.contains { $0.hasUnreadOutput }
    }

    /// A split workspace is named for itself, not for whichever half you clicked last.
    ///
    /// Reading the focused pane meant one workspace wore two names depending on where
    /// the caret was, which is no name at all. Unnamed, it says "Workspace" —
    /// the panes are listed individually in the sidebar, so the workspace only has to
    /// identify the *group*.
    ///
    /// A workspace with one pane *is* that pane. A manual pane name wins, followed
    /// by the complete automatic name assigned when the Workspace opened, then the
    /// pane's derived Host name. Splitting hides those single-pane names and uses
    /// the group's `customTitle` or "Workspace" instead.
    func title(in store: HostLibraryModel, locale: Locale = .current) -> String {
        if isSplit {
            return customTitle ?? AppLocalization.resolve(AppStrings.Workspace.workspace, locale: locale)
        }
        if let customTitle = focusedPane.customTitle { return customTitle }
        return automaticTitle ?? focusedPane.derivedTitle(in: store, locale: locale)
    }

    func subtitle(in store: HostLibraryModel) -> String? {
        if isSplit {
            let count = panes.count
            return String(localized: AppStrings.Workspace.panes(count))
        }
        return focusedPane.subtitle(in: store)
    }

    // MARK: - Mutation

    func focus(_ paneID: Pane.ID) {
        guard layout.pane(paneID) != nil else { return }
        guard focusedPaneID != paneID else { return }
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

    /// Closes a pane. Returns `false` when that emptied the workspace, which the
    /// window reads as "close this workspace too".
    func closePane(_ paneID: Pane.ID) -> Bool {
        guard let remaining = layout.removing(paneID) else { return false }
        layout = remaining
        if layout.pane(focusedPaneID) == nil {
            focusedPaneID = remaining.firstPane.id
        }
        // The name belonged to the group; there is no group left. Keeping it
        // would hide it behind the surviving pane's name and then spring it back
        // over unrelated panes the next time this workspace was split.
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

    /// Preserve the workspace's arrangement and conversation while replacing every
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
            pane.telnetSession?.hasUnreadOutput = false
            pane.serialSession?.hasUnreadOutput = false
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

    func deliverToFocusedTerminal(_ text: String, submit: Bool = false) {
        if let sshSession = focusedPane.sshSession, sshSession.status.isLive {
            deliver(text, from: sshSession, submit: submit)
        } else if let telnetSession = focusedPane.telnetSession, telnetSession.status.isLive {
            telnetSession.insert(text, submit: submit)
        }
    }

    func generateFocusedCommand(using controller: any CommandGenerating) {
        if commandGeneration.isRunning {
            cancelCommandGeneration()
            return
        }
        guard let origin = focusedPane.sshSession else { return }
        let targets = broadcastsInput && canBroadcast ? broadcastTargets : [origin]
        guard targets.allSatisfy(\.canGenerateFromCurrentDraft) else {
            showCommandGenerationFailure(
                String(
                    localized:
                        AppStrings.Workspace.batchCommandGeneratorShellRequirement
                )
            )
            return
        }
        guard let cwd = origin.workingDirectory, !cwd.isEmpty,
            let shell = origin.integratedShell
        else {
            showCommandGenerationFailure(
                String(localized: AppStrings.Workspace.theFocusedShellHasNotReportedItsCurrentDirectory)
            )
            return
        }

        let targetIDs = targets.map(\.id)
        let revisions = Dictionary(
            uniqueKeysWithValues: targets.map {
                ($0.id, $0.commandGeneratorRevision)
            })
        let focusedID = focusedPaneID
        let wasBroadcasting = broadcastsInput && canBroadcast
        commandGeneration.start(
            targetCount: targets.count,
            readContext: {
                let draft = try await origin.requestCurrentDraft()
                return CommandGeneratorContext(
                    draft: draft, shell: shell, cwd: cwd,
                    remoteSystemInfo: origin.remoteSystemInfo
                )
            },
            isCurrent: { [weak self] in
                self?.commandGenerationSnapshotIsCurrent(
                    focusedID: focusedID,
                    wasBroadcasting: wasBroadcasting,
                    targetIDs: targetIDs,
                    revisions: revisions
                ) == true
            },
            generate: { try await controller.generate($0) },
            insert: { command in
                for target in targets { target.replaceCurrentDraft(with: command) }
            }
        )
    }

    func cancelCommandGeneration() {
        guard commandGeneration.isRunning else { return }
        commandGeneration.cancel()
    }

    private func commandGenerationSnapshotIsCurrent(
        focusedID: Pane.ID, wasBroadcasting: Bool,
        targetIDs: [SSHSessionModel.ID], revisions: [SSHSessionModel.ID: UInt64]
    ) -> Bool {
        guard focusedPaneID == focusedID,
            (broadcastsInput && canBroadcast) == wasBroadcasting
        else { return false }
        let targets = wasBroadcasting ? broadcastTargets : focusedPane.sshSession.map { [$0] } ?? []
        guard targets.map(\.id) == targetIDs else { return false }
        return targets.allSatisfy {
            $0.canGenerateFromCurrentDraft && revisions[$0.id] == $0.commandGeneratorRevision
        }
    }

    private func showCommandGenerationFailure(_ message: String) {
        commandGeneration.fail(message)
    }

    /// Keeps each session-to-Workspace relationship correct as panes are merged,
    /// detached, replaced, and tiled. Removed sessions are cleared only when
    /// this Workspace still owns their route; a destination may already have
    /// claimed them during a tree rewrite.
    private func synchronizeInputRouters(previousLayout: SplitNode? = nil) {
        let currentSessions = broadcastTargets
        let currentIDs = Set(currentSessions.map(\.id))
        let currentSFTPChannels = panes.compactMap(\.sftpChannel)
        let currentSFTPIDs = Set(currentSFTPChannels.map(\.id))

        if let previousLayout {
            for sshSession in previousLayout.panes.compactMap(\.sshSession)
            where !currentIDs.contains(sshSession.id) && sshSession.inputRouter === self {
                sshSession.inputRouter = nil
            }
            for sftpChannel in previousLayout.panes.compactMap(\.sftpChannel)
            where !currentSFTPIDs.contains(sftpChannel.id) && sftpChannel.navigationRouter === self {
                sftpChannel.navigationRouter = nil
            }
        }

        for sshSession in currentSessions {
            sshSession.inputRouter = self
        }
        for sftpChannel in currentSFTPChannels {
            sftpChannel.navigationRouter = self
        }

        if !canBroadcast { broadcastsInput = false }
    }

}

extension Workspace: SFTPChannelNavigationRouting {
    func sftpChannel(_ sftpChannel: SFTPChannelModel, didChangePath path: String) {
        guard focusedPane.sftpChannel === sftpChannel else { return }
        lifecycleRouter?.workspaceContextDidChange(self)
    }
}

extension Workspace: SSHSessionInputRouting {
    /// Copies the exact bytes Ghostty produced for a keyboard or paste action.
    /// Sending directly preserves each event's terminal encoding and avoids
    /// feeding broadcast copies back through this router.
    func routeInteractiveInput(_ data: Data, from origin: SSHSessionModel) {
        cancelCommandGeneration()
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

    func sshSessionDidInvalidateCommandGeneration(_: SSHSessionModel) {
        cancelCommandGeneration()
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

    func sshSessionDidChangeRemoteSystemInfo(_ sshSession: SSHSessionModel) {
        guard focusedPane.sshSession === sshSession else { return }
        lifecycleRouter?.workspaceContextDidChange(self)
    }

    func sshSessionDidChangeRemoteWindowTitle(_ sshSession: SSHSessionModel) {
        guard focusedPane.sshSession === sshSession else { return }
        lifecycleRouter?.workspaceRemoteWindowTitleDidChange(self)
    }

    /// Shell EOF is a successful completion, so it closes the shell's pane.
    /// The window owns the last-pane case because removing it also removes and
    /// reselects workspaces. Standalone Workspaces still handle split panes in tests
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

// MARK: - Convenience constructors

extension Workspace {
    func configureConnections(using coordinator: RemoteConnectionCoordinator) {
        for pane in panes { pane.configureConnections(using: coordinator) }
    }

    func configureCommandHistory(using store: CommandHistoryModel) {
        for pane in panes { pane.configureCommandHistory(using: store) }
    }

    func configureSFTPHistory(using store: SFTPHistoryModel) {
        for pane in panes { pane.configureSFTPHistory(using: store) }
    }

    /// A host is required: there is no local terminal to open without one.
    static func sshSession(host: Host, usernameHint: String? = nil) -> Workspace {
        Workspace(pane: .sshSession(host: host, usernameHint: usernameHint))
    }

    /// A host is required, for the same reason a sshSession needs one: there is
    /// nothing to browse without a machine on the other end.
    static func sftpChannel(host: Host, initialPath: String? = nil) -> Workspace {
        Workspace(pane: .sftpChannel(host: host, initialPath: initialPath))
    }

}
