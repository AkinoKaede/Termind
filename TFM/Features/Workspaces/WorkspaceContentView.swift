import GhosttyTerminal
import GlyphixTextFx
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

#if canImport(AppKit)
    import AppKit
#endif

/// The body of a Workspace: its pane tree, laid out with split views.
struct WorkspaceContentView: View {
    let workspace: Workspace
    let isActive: Bool

    @AppStorage(DesktopSettingsKey.showStatusBar) private var showsStatusBar = true
    @Environment(WindowModel.self) private var window

    var body: some View {
        ZStack(alignment: .bottom) {
            SplitNodeView(
                node: workspace.layout,
                workspace: workspace,
                isActive: isActive,
                omittedPaneID: omittedPaneID
            )
            .id(workspace.id)

            if workspace.commandGeneratorState != .idle {
                CommandGeneratorOverlay(state: workspace.commandGeneratorState)
                    .padding(Metrics.Space.l)
                    // Above the floating status capsule, not on top of it.
                    .padding(
                        .bottom,
                        Metrics.StatusBar.overlayClearance(isEnabled: showsStatusBar)
                    )
                    .zIndex(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: workspace.commandGeneratorState)
        .background {
            broadcastShortcut
            terminalFindShortcuts
        }
    }

    /// ⌘B, with no menu item to hang it on.
    ///
    /// Broadcast has a home already — the button on every shell's pane header,
    /// which sits next to the panes it reaches and shows its own state. A menu
    /// item would be a second copy of a control that is visible whenever it is
    /// usable, so the shortcut is registered as a zero-size button that exists
    /// only to own a key equivalent while this workspace is on screen.
    ///
    /// Disabled when there is nothing to broadcast to, so the key falls through
    /// rather than flipping a switch with one wire on it.
    private var broadcastShortcut: some View {
        Button("") { window.toggleBroadcastInput(in: workspace) }
            .termindShortcut("b")
            .disabled(!isActive || !workspace.canBroadcast)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// Function-key and cancel equivalents have no natural menu item. They live
    /// beside the existing invisible ⌘B owner and are disabled on every hidden
    /// workspace, so AppKit never has to choose between two mounted sessions.
    @ViewBuilder
    private var terminalFindShortcuts: some View {
        #if canImport(AppKit)
            let sshSession = workspace.focusedPane.sshSession

            Group {
                // F3 is ⌘G's twin and carries the same mapping: `.previous`
                // walks toward older output, which is the direction that finds
                // matches when a search starts at the bottom of the buffer.
                Button("") { sshSession?.find.presentAndNavigate(.previous) }
                    .termindShortcut(.f3, modifiers: [])
                    .disabled(!isActive || sshSession == nil)

                Button("") { sshSession?.find.presentAndNavigate(.next) }
                    .termindShortcut(.f3, modifiers: .shift)
                    .disabled(!isActive || sshSession == nil)

                Button("") { sshSession?.find.dismiss() }
                    .termindShortcut(.escape, modifiers: [])
                    .disabled(!isActive || sshSession?.find.isPresented != true)

                Button("") { sshSession?.find.dismiss() }
                    .termindShortcut(.escape, modifiers: .shift)
                    .disabled(!isActive || sshSession?.find.isPresented != true)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        #endif
    }

    /// While one of this Workspace's panes is being dragged, its branch collapses
    /// without removing the source view from the hierarchy.
    ///
    /// So the arrangement under the pointer is the one you would actually get:
    /// the remaining panes have already reflowed into the space the dragged one
    /// is leaving, and the drop rectangle lands on that rather than on a layout
    /// you are in the middle of abandoning.
    ///
    /// Keeping the original `PaneView` mounted is required by AppKit: removing
    /// the view that owns the drag can end the native drag session before the
    /// pointer reaches the Navigator. `SplitBranchView` uses this identity only
    /// for temporary geometry; the model tree is unchanged until a drop lands.
    private var omittedPaneID: Pane.ID? {
        guard case .pane(let id)? = window.dragging,
            workspace.layout.pane(id) != nil
        else { return nil }
        return id
    }
}

private struct CommandGeneratorOverlay: View {
    let state: CommandGeneratorState

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: Metrics.Space.s) {
            symbol
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.vertical, Metrics.Space.l)
        .termindTransientOverlaySurface()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .readingDraft, .generating:
            ProgressView().controlSize(.small)
        case .inserted:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch state {
        case .idle: ""
        case .readingDraft, .generating:
            AppLocalization.resolve(AppStrings.Workspace.generatingCommand, locale: locale)
        case .inserted:
            AppLocalization.resolve(AppStrings.Workspace.commandInserted, locale: locale)
        case .failed:
            AppLocalization.resolve(AppStrings.Workspace.commandGenerationFailed, locale: locale)
        }
    }

    private var detail: String? {
        switch state {
        case .idle: nil
        case .readingDraft, .generating:
            AppLocalization.resolve(AppStrings.Workspace.thisMayTakeAMoment, locale: locale)
        case .inserted:
            AppLocalization.resolve(AppStrings.Workspace.pressReturnToRun, locale: locale)
        case .failed(let message): message
        }
    }
}

/// Recursive layout for `SplitNode`.
private struct SplitNodeView: View {
    let node: SplitNode
    let workspace: Workspace
    let isActive: Bool
    let omittedPaneID: Pane.ID?

    var body: some View {
        switch node {
        case .leaf(let pane):
            // Identified, so the panes that survive a reflow keep their state
            // instead of being torn down and rebuilt as the tree reshapes.
            PaneView(pane: pane, workspace: workspace, isActive: isActive)
                .id(pane.id)
                .opacity(omittedPaneID == pane.id ? 0 : 1)
                .allowsHitTesting(omittedPaneID != pane.id)
                .accessibilityHidden(omittedPaneID == pane.id)
        case .split(let branch):
            SplitBranchView(
                branch: branch,
                workspace: workspace,
                isActive: isActive,
                omittedPaneID: omittedPaneID
            )
        }
    }
}

/// One division, laid out from its own stored fraction.
///
/// Deliberately not `HSplitView`/`VSplitView`. Those own the divider position,
/// which cost us two things: a drop previewed as "the right half" arrived at
/// whatever width AppKit picked, and resizing the workspace handed the new space to
/// one child instead of both. Sizing from `branch.fraction` on every layout pass
/// makes the first exact and the second proportional for free — there is no
/// resize handler here because there is nothing to handle.
private struct SplitBranchView: View {
    let branch: SplitNode.Branch
    let workspace: Workspace
    let isActive: Bool
    let omittedPaneID: Pane.ID?

    /// The fraction previewed while the pointer is down.
    ///
    /// Keeping this local matters for both correctness and responsiveness:
    /// publishing `Workspace.layout` for every mouse event rebuilds the whole
    /// pane tree, and measuring a moving divider in its own coordinate space
    /// makes the gesture's translation move underneath the pointer. The drag
    /// therefore uses global coordinates, previews locally, and commits once.
    @State private var draggedFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = length(of: proxy.size)
            let lengths = childLengths(in: total)

            switch branch.axis {
            case .horizontal:
                HStack(spacing: 0) {
                    child(branch.first)
                        .frame(width: lengths.first)
                    divider(total: total, isCollapsed: lengths.divider == 0)
                    child(branch.second)
                        .frame(width: lengths.second)
                }
            case .vertical:
                VStack(spacing: 0) {
                    child(branch.first)
                        .frame(height: lengths.first)
                    divider(total: total, isCollapsed: lengths.divider == 0)
                    child(branch.second)
                        .frame(height: lengths.second)
                }
            }
        }
    }

    private func child(_ node: SplitNode) -> some View {
        SplitNodeView(
            node: node,
            workspace: workspace,
            isActive: isActive,
            omittedPaneID: omittedPaneID
        )
        .clipped()
    }

    // MARK: - Divider

    /// A hairline to look at inside a wider band to grab: one point of visible
    /// line is not a pointer target. Negative padding keeps the full grab band
    /// centred over both panes while only the hairline consumes layout space.
    private func divider(total: CGFloat, isCollapsed: Bool) -> some View {
        let grabInset = (Metrics.Split.dividerHitLength - Metrics.Split.dividerThickness) / 2
        return ZStack {
            Color.clear.contentShape(.rect)
            Rectangle().fill(.separator).frame(
                width: branch.axis == .horizontal ? Metrics.Split.dividerThickness : nil,
                height: branch.axis == .vertical ? Metrics.Split.dividerThickness : nil
            )
        }
        .frame(
            width: branch.axis == .horizontal
                ? (isCollapsed ? 0 : Metrics.Split.dividerHitLength) : nil,
            height: branch.axis == .vertical
                ? (isCollapsed ? 0 : Metrics.Split.dividerHitLength) : nil
        )
        .padding(.horizontal, branch.axis == .horizontal && !isCollapsed ? -grabInset : 0)
        .padding(.vertical, branch.axis == .vertical && !isCollapsed ? -grabInset : 0)
        .opacity(isCollapsed ? 0 : 1)
        .allowsHitTesting(!isCollapsed)
        .pointerStyle(branch.axis == .horizontal ? .columnResize : .rowResize)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let moved =
                        branch.axis == .horizontal
                        ? value.translation.width
                        : value.translation.height
                    let usable = usableLength(in: total)
                    guard usable > 0 else { return }
                    draggedFraction = clamp(branch.fraction + moved / usable, in: total)
                }
                .onEnded { value in
                    let moved =
                        branch.axis == .horizontal
                        ? value.translation.width
                        : value.translation.height
                    let usable = usableLength(in: total)
                    guard usable > 0 else {
                        draggedFraction = nil
                        return
                    }
                    let final = clamp(branch.fraction + moved / usable, in: total)
                    draggedFraction = nil
                    guard final != branch.fraction else { return }
                    workspace.setFraction(final, forBranch: branch.id)
                }
        )
    }

    // MARK: - Measurement

    private func length(of size: CGSize) -> CGFloat {
        branch.axis == .horizontal ? size.width : size.height
    }

    private func usableLength(in total: CGFloat) -> CGFloat {
        max(0, total - Metrics.Split.dividerThickness)
    }

    private func clampedFirstLength(in total: CGFloat) -> CGFloat {
        usableLength(in: total) * clamp(draggedFraction ?? branch.fraction, in: total)
    }

    private func childLengths(in total: CGFloat) -> (
        first: CGFloat, divider: CGFloat, second: CGFloat
    ) {
        if subtreeDisappearsWhenOmitted(branch.first) {
            return (0, 0, total)
        }
        if subtreeDisappearsWhenOmitted(branch.second) {
            return (total, 0, 0)
        }

        let first = clampedFirstLength(in: total)
        let second = max(0, total - first - Metrics.Split.dividerThickness)
        return (first, Metrics.Split.dividerThickness, second)
    }

    private func subtreeDisappearsWhenOmitted(_ node: SplitNode) -> Bool {
        guard let omittedPaneID, node.pane(omittedPaneID) != nil else { return false }
        return node.removing(omittedPaneID) == nil
    }

    /// Keeps both sides above `minPaneLength` — but only while there is room for
    /// that. Below it the clamp inverts and pins the split at the middle, which
    /// is the least surprising thing a pane too small for either rule can do.
    private func clamp(_ fraction: Double, in total: CGFloat) -> Double {
        let usable = usableLength(in: total)
        guard usable > 0 else { return 0.5 }
        let floor = Metrics.Split.minPaneLength / usable
        guard floor * 2 <= 1 else { return 0.5 }
        return min(max(fraction, floor), 1 - floor)
    }
}

/// One pane: a header naming it, its content, and the focus affordance — the
/// first and last of which only exist while the workspace is split.
///
/// Every pane is a drop target, not just the empty ones. Dragging a workspace onto the
/// edge of a live terminal splits along that edge and folds the dragged panes in
/// on that side, so "put these two side by side" is one move rather than
/// Split-then-drag. Dropping on an empty pane still replaces it outright —
/// there is nothing there to sit beside.
private struct PaneView: View {
    let pane: Pane
    let workspace: Workspace
    let isActive: Bool

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var localFileDropRequest: LocalFileDropRequest?
    @State private var sftpRemoteDropRequest: SFTPRemoteDropRequest?
    @State private var nativeDropKind: NativeDropKind?
    @FocusState private var titleFieldFocused: Bool

    private var isFocused: Bool { workspace.focusedPaneID == pane.id }
    private var showsHoverControls: Bool {
        #if DEBUG
            if ScreenshotDemoConfiguration.active?.scene == .workspace, isFocused {
                return true
            }
        #endif
        return isHovering
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.isSplit {
                header
                if pane.kind == .empty { Divider() }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if workspace.isSplit {
                Rectangle()
                    .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        // Keep the native receiver mounted above terminal/table content. It
        // reads the live drag and displayed workspace without waiting for a
        // SwiftUI render, and passes ordinary pointer events through.
        .overlay { layoutDropTarget }
        .overlay { paneFileDropDecoration }
        // This must be the outermost pane overlay. Both Ghostty and SwiftUI's
        // macOS Table install native AppKit views above their own SwiftUI
        // modifiers, so a child-level upload target never enters the drag
        // responder chain.
        .overlay { paneFileDropTarget }
        .animation(
            Motion.dropTarget(reduceMotion: reduceMotion),
            value: nativeDropKind
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture {
            window.dragging = nil
            workspace.focus(pane.id)
        }
    }

    private var layoutDropTarget: some View {
        let controller = PaneLayoutDropController(window: window, workspace: workspace, pane: pane)
        return WorkspaceLayoutDropTarget(
            draggedID: { controller.draggedID },
            preview: { point, size in controller.preview(at: point, in: size) },
            perform: { point, size in controller.perform(at: point, in: size) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var paneFileDropTarget: some View {
        switch pane.content {
        case .sshSession:
            NativeDropTarget(
                targetedKind: $nativeDropKind,
                acceptedKinds: [.files, .sftpItems, .terminalPath],
                isEnabled: isActive && window.dragging == nil,
                receive: receivePaneDrop
            )
        case .sftpChannel:
            NativeDropTarget(
                targetedKind: $nativeDropKind,
                acceptedKinds: [.files, .sftpItems],
                isEnabled: isActive && window.dragging == nil,
                receive: receivePaneDrop
            )
        case .telnetSession, .serialSession:
            NativeDropTarget(
                targetedKind: $nativeDropKind,
                acceptedKinds: [.terminalPath],
                isEnabled: isActive && window.dragging == nil,
                receive: receivePaneDrop
            )
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private var paneFileDropDecoration: some View {
        if nativeDropKind != nil, let presentation = paneDropPresentation {
            DropTargetOverlay(presentation: presentation)
        }
    }

    private var paneDropPresentation: DropTargetPresentation? {
        // Path insertion uses the native copy cursor, not the upload overlay.
        guard nativeDropKind != .terminalPath else { return nil }
        switch pane.content {
        case .sshSession(let sshSession):
            if let problem = TerminalUploadAvailability.problem(
                isConnected: sshSession.status == .connected,
                hasTransferConfiguration: sshSession.transferSnapshot != nil,
                isWorkingDirectoryPending: sshSession.homeResolution.isPending,
                workingDirectory: sshSession.workingDirectory
            ) {
                return DropTargetPresentation(
                    title: String(localized: AppStrings.SFTP.uploadUnavailable),
                    detail: problem,
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .unavailable
                )
            }
            let hostName = app.hostLibrary.host(sshSession.hostID)?.name ?? sshSession.title
            return DropTargetPresentation(
                title: nativeDropKind == .sftpItems
                    ? String(localized: AppStrings.Workspace.copyTo(hostName))
                    : String(localized: AppStrings.Workspace.uploadTo(hostName)),
                detail: sshSession.displayPath(
                    RemotePath.normalized(sshSession.workingDirectory ?? "/")
                ),
                systemImage: nativeDropKind == .sftpItems
                    ? "doc.on.doc.fill" : "arrow.up.doc.fill"
            )
        case .sftpChannel(let sftpChannel):
            guard sftpChannel.status == .connected else {
                return DropTargetPresentation(
                    title: String(localized: AppStrings.SFTP.uploadUnavailable),
                    detail: String(localized: AppStrings.Workspace.theSftpChannelIsNotConnected),
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .unavailable
                )
            }
            let hostName =
                app.hostLibrary.host(sftpChannel.hostID)?.name
                ?? String(localized: AppStrings.SFTP.sftp)
            return DropTargetPresentation(
                title: nativeDropKind == .sftpItems
                    ? String(localized: AppStrings.Workspace.copyTo(hostName))
                    : String(localized: AppStrings.Workspace.uploadTo(hostName)),
                detail: sftpChannel.displayPath(sftpChannel.path),
                systemImage: nativeDropKind == .sftpItems
                    ? "doc.on.doc.fill" : "arrow.up.doc.fill"
            )
        case .telnetSession, .serialSession, .empty:
            return nil
        }
    }

    private func receivePaneDrop(_ payload: NativeDropPayload) -> Bool {
        if let text = payload.terminalPath {
            let owner: PersistentTerminalViewOwner
            switch pane.content {
            case .sshSession(let session): owner = session.terminalViewOwner
            case .telnetSession(let session): owner = session.terminalViewOwner
            case .serialSession(let session): owner = session.terminalViewOwner
            case .sftpChannel, .empty: return false
            }
            workspace.focus(pane.id)
            return owner.pasteDroppedPath(text)
        }
        if let data = payload.sftpItems {
            switch pane.content {
            case .sshSession, .sftpChannel:
                sftpRemoteDropRequest = SFTPRemoteDropRequest(data: data)
                return true
            case .telnetSession, .serialSession, .empty:
                return false
            }
        }
        guard !payload.fileURLs.isEmpty else { return false }
        localFileDropRequest = LocalFileDropRequest(urls: payload.fileURLs)
        return true
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .sshSession(let sshSession):
            TerminalPlaceholderView(
                sshSession: sshSession,
                workspace: workspace,
                isVisible: isActive,
                requestsFocus: isActive && isFocused && !window.isToolbarFindFocused && !window.isQuickOpenPresented,
                externalFileDrop: localFileDropRequest,
                externalRemoteDrop: sftpRemoteDropRequest,
                closePane: { window.closePane(pane.id) }
            )
        case .telnetSession(let telnetSession):
            TelnetTerminalView(
                session: telnetSession,
                isVisible: isActive,
                requestsFocus: isActive && isFocused && !window.isToolbarFindFocused && !window.isQuickOpenPresented,
                closePane: { window.closePane(pane.id) }
            )
        case .sftpChannel(let sftpChannel):
            SFTPBrowserView(
                sftpChannel: sftpChannel,
                isPaneFocused: isActive && isFocused,
                focusPane: { workspace.focus(pane.id) },
                externalFileDrop: localFileDropRequest,
                externalRemoteDrop: sftpRemoteDropRequest,
                closePane: { window.closePane(pane.id) }
            )
        case .serialSession(let serialSession):
            SerialTerminalView(
                session: serialSession,
                isVisible: isActive,
                requestsFocus: isActive && isFocused && !window.isToolbarFindFocused && !window.isQuickOpenPresented,
                closePane: { window.closePane(pane.id) }
            )
        case .empty:
            EmptyPaneView()
        }
    }

    // MARK: - Header

    /// The strip naming a pane, present only while the workspace is split — a
    /// single-pane workspace is already named by its workspace, and a second copy of that
    /// string sitting on the content says nothing.
    ///
    /// Reserved space rather than an overlay. A label floating over a terminal
    /// covers the first line of output, which is usually the line you opened the
    /// pane to read.
    ///
    /// The name is the drag handle, and nothing else in the row is: a terminal's
    /// body belongs to selecting text, so making the whole pane draggable would
    /// trade something you do constantly for something you do rarely.
    @ViewBuilder
    private var header: some View {
        if presentsConnectionJourney {
            headerContent.background {
                ConnectionJourneyBackground()
            }
        } else if let state = terminalState {
            headerContent.background { TerminalBackground(state: state) }
        } else if pane.kind == .sftpChannel {
            headerContent.background(TermindColor.windowSurface)
        } else {
            headerContent.termindGlassBar()
        }
    }

    private var terminalState: TerminalViewState? {
        switch pane.content {
        case .sshSession(let session): session.terminalState
        case .telnetSession(let session): session.terminalState
        case .serialSession(let session): session.terminalState
        case .sftpChannel, .empty: nil
        }
    }

    private var presentsConnectionJourney: Bool {
        switch pane.content {
        case .sshSession(let session):
            session.connectionJourney.isPresented
        case .telnetSession(let session):
            session.connectionJourney.isPresented
        case .sftpChannel(let session):
            session.connectionJourney.isPresented
        case .serialSession(let session):
            session.connectionJourney.isPresented
        case .empty:
            false
        }
    }

    private var headerContent: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: pane.symbol)
                .font(.system(size: Metrics.Split.headerIconSize))
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField(
                    AppStrings.Workspace.paneName.swiftUIKey, text: $draftTitle.singleLineText, axis: .horizontal
                ).singleLinePaste().lineLimit(
                    1
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($titleFieldFocused)
                .onSubmit(commitRename)
                .onExitCommand { isRenaming = false }
            } else {
                title
            }

            Spacer(minLength: Metrics.Space.xs)

            broadcastToggle

            // The close button appears only under the pointer, the same rule the
            // workspace bar follows: identity is what you want while scanning, the
            // close button only once you are aiming at something.
            if showsHoverControls {
                Button {
                    window.closePane(pane.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text(AppStrings.Workspace.closePane))
            }
        }
        .padding(.horizontal, Metrics.Space.m)
        .frame(height: Metrics.Split.headerHeight)
    }

    /// Broadcast: type here, and every shell in the Workspace hears it.
    ///
    /// Only on a shell's header, and only while there is a second shell to reach
    /// — a file browser is not a participant, and a switch with one wire on it
    /// is a control for nothing. See `Workspace.canBroadcast`.
    ///
    /// It follows the ×'s rule exactly — the pointer reveals it, on or off — so
    /// a header you are not aiming at is only an icon and a name, and the row
    /// stays quiet while you read the pane under it. The cost is real and
    /// accepted: a live broadcast is invisible from across the window, and what
    /// says so is the accent tint the moment you point at any header.
    ///
    /// No `keyboardShortcut` here. `WorkspaceContentView.broadcastShortcut` owns ⌘B;
    /// declared in both places AppKit picks one arbitrarily.
    @ViewBuilder
    private var broadcastToggle: some View {
        if pane.kind == .sshSession, workspace.canBroadcast {
            let isOn = workspace.broadcastsInput
            if showsHoverControls {
                Button {
                    withAnimation(Motion.workspaceSwitch) {
                        window.toggleBroadcastInput(in: workspace)
                    }
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .medium))
                        .frame(width: 14, height: 14)
                        .background(
                            isOn ? Color.accentColor.opacity(0.18) : .clear,
                            in: .rect(cornerRadius: Metrics.Radius.small)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .help(Text(AppStrings.Workspace.broadcastInputToEverySshSessionInThisWorkspaceB))
                .accessibilityLabel(Text(AppStrings.Workspace.broadcastInput))
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    /// The draggable half of the header.
    ///
    /// The drag preview is spelled out rather than left to macOS, which would
    /// otherwise snapshot the source view — the old grip icon flying around said
    /// nothing about which pane was in the air. A name is what identifies a
    /// pane, so a name is what follows the cursor.
    @ViewBuilder
    private var title: some View {
        let label = Text(displayedTitle)
            .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .contentShape(.rect)
            .onTapGesture(count: 2, perform: beginRename)
            .accessibilityLabel(Text(pane.title(in: app.hostLibrary)))

        if pane.isCombinable {
            label
                .pointerStyle(.grabIdle)
                .help(Text(AppStrings.Workspace.dragToMoveThisPaneDoubleClickToRename))
                .modifier(
                    WorkspaceLayoutDragSource(
                        window: window, payload: .pane(pane.id),
                        title: displayedTitle, symbol: pane.symbol,
                        onTearOff: { point in
                            app.mainWindows.movePane(pane.id, from: window, at: point)
                        }
                    ))
        } else if pane.kind.isRenameable {
            label
                .help(Text(AppStrings.Workspace.doubleClickToRename))
        } else {
            // An unfilled slot is the only thing that reaches here, and it is
            // named after the state it is in — there is nothing to call it but
            // Empty, and it stops existing the moment something fills it.
            label
        }
    }

    private func beginRename() {
        guard pane.kind.isRenameable else { return }
        draftTitle = displayedTitle
        isRenaming = true
        titleFieldFocused = true
    }

    private func commitRename() {
        window.rename(pane: pane.id, to: draftTitle)
        isRenaming = false
    }

    private var displayedTitle: String {
        workspace.isSplit
            ? pane.sidebarTitle(in: app.hostLibrary)
            : workspace.title(in: app.hostLibrary)
    }
}

/// The landing page, and what a window with no workspaces falls back to.
///
/// Deliberately a pane rather than an overlay, so closing the last workspace does not
/// leave a window with no content at all.
///
/// This is also where search lives. The sidebar is a navigator — a fixed list of
/// destinations — so putting a field there would have meant a control that
/// filters something two columns away. Here the field and its results are the
/// same view, and one input covers both jobs a launcher has: find a host you
/// saved, or type `user@host` for one you did not.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var query = ""
    @State private var hasSubmitted = false
    @State private var actionError: String?
    @State private var welcomeMessage = " "
    @FocusState private var isSearchFocused: Bool

    private var welcomeGreetings: [String] {
        [
            String(localized: AppStrings.Workspace.helloIMTermind),
            String(localized: AppStrings.Workspace.commandWithEaseStayInControl),
            String(localized: AppStrings.Workspace.sshAndSftpWithAnAssistantAtHand),
        ]
    }

    private var welcomePrompts: [String] {
        [
            String(localized: AppStrings.Workspace.whatWouldYouLikeToDoConfirmation),
            String(localized: AppStrings.Workspace.whatDoYouFeelLikeDoingConfirmation),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.Space.xxl) {
                header
                searchField
                actions
                results
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.Space.xxl)
            .padding(.horizontal, Metrics.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TermindColor.windowSurface)
        .onAppear { isSearchFocused = true }
        .onChange(of: window.welcomeSearchFocusRequest) { _, _ in
            isSearchFocused = true
        }
    }

    private var header: some View {
        GlyphixText(welcomeMessage)
            .glyphixTextFont(.systemFont(ofSize: 30, weight: .semibold))
            .glyphixTextColor(.labelColor)
            .glyphixTextAnimationDisabled(accessibilityReduceMotion)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: welcomeMessage))
            .task {
                let greeting = welcomeGreetings.randomElement() ?? welcomeGreetings[0]
                let prompt = welcomePrompts.randomElement() ?? welcomePrompts[0]

                // Let GlyphixText mount before its first animated transition. Updating
                // immediately can be folded into the initial render and skip the greeting.
                if !accessibilityReduceMotion {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { return }
                welcomeMessage = greeting

                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                welcomeMessage = prompt
            }
    }

    // MARK: - Search

    private var searchField: some View {
        TermindSearchField(
            text: $query, prompt: AppStrings.Workspace.searchHostsOrTemplatesOrTypeSshUserHost, density: .prominent
        )
        .focused($isSearchFocused)
        .onSubmit(submit)
        .onChange(of: query) { _, _ in
            hasSubmitted = false
            actionError = nil
        }
        .help(AppStrings.Workspace.supportedSSHOptions.swiftUIKey)
    }

    private var matches: [Host] {
        query.isEmpty || isSSHCommand ? [] : app.hostLibrary.searchHosts(query)
    }

    private var matchingTemplates: [WorkspaceTemplate] {
        guard !query.isEmpty, !isSSHCommand else { return [] }
        return app.hostLibrary.sortedWorkspaceTemplates.filter { template in
            template.name.localizedCaseInsensitiveContains(query)
                || template.layout.hostIDs.contains { hostID in
                    app.hostLibrary.host(hostID)?.name.localizedCaseInsensitiveContains(query) == true
                }
        }
    }

    private var isSSHCommand: Bool { QuickConnectParser.isCommand(query) }

    private var resolution: Result<QuickConnectTarget, any Error>? {
        guard matches.isEmpty, matchingTemplates.isEmpty,
            case .connection(let input) = QuickConnectParser.parse(query, locale: locale)
        else { return nil }
        return Result { try app.resolveQuickConnect(input, locale: locale) }
    }

    private var adHoc: QuickConnectTarget? { try? resolution?.get() }

    private var connectionError: String? {
        if let actionError { return actionError }
        switch QuickConnectParser.parse(query, locale: locale) {
        case .invalid(let message): return message
        case .incomplete(let message): return hasSubmitted ? message : nil
        default: break
        }
        if case .failure(let error) = resolution { return error.localizedDescription }
        return nil
    }

    private func submit() {
        hasSubmitted = true
        if let template = matchingTemplates.first {
            window.openWorkspaceTemplate(template)
        } else if let host = matches.first {
            app.open(host, as: .preferredTerminal, in: window)
        } else if let adHoc {
            connect(adHoc)
            return
        } else {
            return
        }
        query = ""
    }

    private func connect(_ target: QuickConnectTarget) {
        app.openQuickConnect(target, in: window)
        query = ""
    }

    private func save(_ target: QuickConnectTarget) {
        do {
            let host = try app.saveQuickConnect(target)
            query = host.name
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private var actions: some View {
        WelcomeGlassGroup(spacing: Metrics.Space.l) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.Space.l) {
                    actionButtons
                }
                VStack(spacing: Metrics.Space.s) {
                    actionButtons
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        WelcomeActionButton(title: AppStrings.Common.connect, symbol: MenuSymbol.connect) {
            app.connect(in: window)
        }
        WelcomeActionButton(title: AppStrings.Vault.batchStartup, symbol: MenuSymbol.batchStartup) {
            app.batchStartup(in: window)
        }
        WelcomeActionButton(title: AppStrings.Assistant.newChat, symbol: MenuSymbol.newChat) {
            window.openNewAssistantChat()
        }
    }

    // MARK: - Results

    /// Recents when the field is empty, matches when it is not. One list in one
    /// place, so typing narrows what you were already looking at instead of
    /// replacing it with a different-looking panel.
    @ViewBuilder
    private var results: some View {
        if query.isEmpty {
            let templates = app.hostLibrary.sortedWorkspaceTemplates
            if !templates.isEmpty {
                section(AppStrings.Workspace.workspaceTemplates) {
                    ForEach(templates) { template in
                        WelcomeWorkspaceTemplateRow(template: template)
                    }
                }
            }
            let hosts = app.connectionHistory.recentLocalHosts(
                in: app.hostLibrary, limit: max(0, 6 - templates.count))
            if !hosts.isEmpty {
                section(AppStrings.Workspace.recents) {
                    ForEach(hosts) { recent in
                        WelcomeHostRow(host: recent.host)
                    }
                }
            }
        } else {
            if !matchingTemplates.isEmpty {
                section(AppStrings.Workspace.workspaceTemplates) {
                    ForEach(matchingTemplates) { template in
                        WelcomeWorkspaceTemplateRow(template: template)
                    }
                }
            }
            if !matches.isEmpty {
                section(AppStrings.Vault.hosts) {
                    ForEach(matches) { host in
                        WelcomeHostRow(host: host)
                    }
                }
            }
            if let adHoc {
                section(adHoc.isSaved ? AppStrings.Vault.hosts : AppStrings.Workspace.connectOnce) {
                    WelcomeQuickConnectRow(target: adHoc, connect: connect, save: save)
                }
            }
            if let connectionError {
                Text(connectionError)
                    .foregroundStyle(.secondary)
            } else if adHoc == nil, !isSSHCommand, matchingTemplates.isEmpty, matches.isEmpty {
                Text(AppStrings.Workspace.noHostsOrWorkspaceTemplatesMatch(query))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            WelcomeGlassGroup(spacing: Metrics.Space.m) {
                VStack(spacing: Metrics.Space.m) {
                    content()
                }
            }
        }
    }
}

/// Liquid Glass renders neighbouring controls as one responsive family on
/// macOS 26. Earlier systems keep the same layout while each child uses the
/// native material fallback supplied by `termindGlassSurface`.
private struct WelcomeGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct WelcomeActionButton: View {
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.vertical, Metrics.Space.s)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .termindGlassCapsule(isInteractive: true)
    }
}

private struct WelcomeLeadingIcon: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.Welcome.leadingIconSize * 0.25)
            .fill(tint.opacity(0.16))
            .frame(
                width: Metrics.Welcome.leadingIconSize,
                height: Metrics.Welcome.leadingIconSize
            )
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

private struct WelcomeWorkspaceTemplateRow: View {
    let template: WorkspaceTemplate

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isRenaming = false
    @State private var renameTitle = ""

    @ViewBuilder
    var body: some View {
        content
            .termindGlassSurface(
                cornerRadius: Metrics.Radius.medium,
                isInteractive: !isRenaming
            )
            .contextMenu {
                Button(AppStrings.Common.rename.swiftUIKey, systemImage: MenuSymbol.rename) { beginRename() }
                Divider()
                DestructiveMenuButton(AppStrings.Common.delete) {
                    if !app.hostLibrary.deleteWorkspaceTemplate(template.id) {
                        window.workspaceTemplateNotice = app.hostLibrary.storageError
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            row
        } else {
            Button {
                window.openWorkspaceTemplate(template)
            } label: {
                row
            }
            .buttonStyle(.plain)
        }
    }

    private var row: some View {
        HStack(spacing: Metrics.Space.m) {
            WelcomeLeadingIcon(symbol: MenuSymbol.workspace)
            if isRenaming {
                SidebarInlineRenameField(
                    text: $renameTitle,
                    prompt: String(localized: AppStrings.Workspace.workspaceName),
                    isSelected: false,
                    controlActiveState: controlActiveState,
                    onSubmit: commitRename,
                    onCancel: cancelRename
                ).singleLinePaste()
                    .frame(height: 18)
            } else {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(template.name)
                        .lineLimit(1)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Metrics.Space.m)
            Text(AppStrings.Workspace.panes(template.layout.paneCount))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, Metrics.Space.l)
        .frame(
            maxWidth: .infinity,
            minHeight: Metrics.Welcome.rowHeight,
            maxHeight: Metrics.Welcome.rowHeight,
            alignment: .leading
        )
        .contentShape(.rect)
    }

    private func beginRename() {
        renameTitle = template.name
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        if !app.hostLibrary.renameWorkspaceTemplate(template.id, to: renameTitle) {
            window.workspaceTemplateNotice = app.hostLibrary.storageError
        }
    }

    private func cancelRename() {
        isRenaming = false
        renameTitle = ""
    }

    private var summary: String {
        template.layout.panes.map { pane in
            switch pane {
            case .ssh(let hostID):
                "\(app.hostLibrary.host(hostID)?.name ?? String(localized: AppStrings.Workspace.unavailableHost)) · SSH"
            case .mosh(let hostID):
                "\(app.hostLibrary.host(hostID)?.name ?? String(localized: AppStrings.Workspace.unavailableHost)) · Mosh"
            case .eternalTerminal(let hostID):
                "\(app.hostLibrary.host(hostID)?.name ?? String(localized: AppStrings.Workspace.unavailableHost)) · Eternal Terminal"
            case .telnet(let hostID):
                "\(app.hostLibrary.host(hostID)?.name ?? String(localized: AppStrings.Workspace.unavailableHost)) · Telnet"
            case .sftp(let hostID):
                "\(app.hostLibrary.host(hostID)?.name ?? String(localized: AppStrings.Workspace.unavailableHost)) · SFTP"
            case .empty:
                String(localized: AppStrings.Workspace.emptyPane)
            }
        }.joined(separator: ", ")
    }
}

/// A host offered on the Welcome page. Click connects — the page exists to get
/// you onto a machine, and anything else is a right-click away.
private struct WelcomeHostRow: View {
    let host: Host

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var confirmsHistoryClear = false
    @State private var isMenuPresented = false

    var body: some View {
        Button {
            app.open(host, as: .preferredTerminal, in: window)
        } label: {
            HStack(spacing: Metrics.Space.m) {
                WelcomeHostIcon(
                    host: host,
                    status: app.hostLibrary.status(of: host.id)
                )
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(host.name)
                        .lineLimit(1)
                    // Resolved through the store, so a quick-connect row that
                    // matched a saved identity shows the login it will actually use.
                    Text(app.hostLibrary.preferredTerminalLoginAddress(for: host))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Metrics.Space.m)
                trailing
            }
            .font(.callout)
            .padding(.horizontal, Metrics.Space.l)
            .frame(
                maxWidth: .infinity,
                minHeight: Metrics.Welcome.rowHeight,
                maxHeight: Metrics.Welcome.rowHeight,
                alignment: .leading
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .termindGlassSurface(cornerRadius: Metrics.Radius.medium, isInteractive: true)
        .overlay {
            // Build a native menu per click. SwiftUI's live context menu can shrink
            // its popup window when the greeting updates during menu tracking.
            NativeRowContextMenu(entries: { contextMenu }, isPresented: $isMenuPresented)
        }
        .overlay {
            if isMenuPresented {
                RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            AppStrings.Workspace.clearRecentConnectionsConfirmation, isPresented: $confirmsHistoryClear,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.clearHistory.swiftUIKey, role: .destructive) {
                app.connectionHistory.clear(for: host.id)
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Workspace.clearHostHistoryWarning)
        }
    }

    private var contextMenu: [NativeMenuEntry] {
        HostMenuEntries.entries(for: host, app: app, window: window, includesDuplicate: true)
            + [
                .separator,
                NativeMenuEntry(
                    title: AppStrings.Common.delete, symbol: MenuSymbol.delete,
                ) {
                    if DeletionContentCategory.recordedContent.requiresConfirmation(for: .clearCollection) {
                        confirmsHistoryClear = true
                    } else {
                        app.connectionHistory.clear(for: host.id)
                    }
                },
            ]
    }

    @ViewBuilder
    private var trailing: some View {
        if let date = app.lastConnectedLocallyAt(for: host.id) {
            Text(date, format: .relative(presentation: .numeric))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct WelcomeHostIcon: View {
    let host: Host
    let status: ConnectionStatus

    var body: some View {
        HostConnectionIcon(
            host: host, size: Metrics.Welcome.leadingIconSize, status: status,
            badgeStyle: .welcome(
                background: TermindColor.windowSurface, border: TermindColor.separator.opacity(0.8)
            )
        )
    }
}

/// A resolved command preview. Only the explicit actions open or save it.
private struct WelcomeQuickConnectRow: View {
    let target: QuickConnectTarget
    var connect: (QuickConnectTarget) -> Void
    var save: (QuickConnectTarget) -> Void

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            WelcomeLeadingIcon(symbol: MenuSymbol.connect)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.loginAddress)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .help(target.loginAddress)
                if target.route.hosts.count > 1 {
                    Text(target.routeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(target.routeSummary)
                }
                Text(target.isSaved ? AppStrings.Workspace.saved : AppStrings.Workspace.notSaved)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Metrics.Space.m)
            Button(AppStrings.Common.connect.swiftUIKey) { connect(target) }
            if !target.isSaved {
                Button(AppStrings.Common.save.swiftUIKey) { save(target) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.s)
        .frame(maxWidth: .infinity, minHeight: Metrics.Welcome.rowHeight, alignment: .leading)
        .termindGlassSurface(cornerRadius: Metrics.Radius.medium)
    }
}
