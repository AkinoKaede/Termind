import GlyphixTextFx
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

/// The body of a Workspace: its pane tree, laid out with split views.
struct WorkspaceContentView: View {
    let workspace: Workspace
    let isActive: Bool

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
                    .padding(.bottom, Metrics.StatusBar.overlayClearance)
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
        Button("") { workspace.broadcastsInput.toggle() }
            .keyboardShortcut("b")
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
            let f3 = KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!))
            let sshSession = workspace.focusedPane.sshSession

            Group {
                // F3 is ⌘G's twin and carries the same mapping: `.previous`
                // walks toward older output, which is the direction that finds
                // matches when a search starts at the bottom of the buffer.
                Button("") { sshSession?.presentFindAndNavigate(.previous) }
                    .keyboardShortcut(f3, modifiers: [])
                    .disabled(!isActive || sshSession == nil)

                Button("") { sshSession?.presentFindAndNavigate(.next) }
                    .keyboardShortcut(f3, modifiers: .shift)
                    .disabled(!isActive || sshSession == nil)

                Button("") { sshSession?.dismissFind() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!isActive || sshSession?.isFindPresented != true)

                Button("") { sshSession?.dismissFind() }
                    .keyboardShortcut(.escape, modifiers: .shift)
                    .disabled(!isActive || sshSession?.isFindPresented != true)
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
    /// the view that owns `.onDrag` can end the native drag session before the
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

    var body: some View {
        VStack(spacing: Metrics.Space.s) {
            symbol
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.vertical, Metrics.Space.l)
        .termindGlassSurface(cornerRadius: Metrics.Radius.large)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .allowsHitTesting(false)
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
        case .readingDraft: String(localized: "Reading current input…")
        case .generating: String(localized: "Generating command…")
        case .inserted: String(localized: "Command inserted — press Return to run")
        case .failed: String(localized: "Couldn't generate command")
        }
    }

    private var detail: String {
        switch state {
        case .idle: ""
        case .readingDraft:
            String(localized: "Reading the focused shell's edit buffer.")
        case .generating:
            String(
                localized:
                    "Only the current input, shell, working directory, and available system details are sent."
            )
        case .inserted(let targetCount):
            targetCount == 1
                ? String(localized: "Review the command before running it.")
                : String(localized: "Inserted into \(targetCount) broadcast terminals.")
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
    @TerminalAppearanceSettings private var terminalAppearance

    @State private var dropZone: PaneDropZone?
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var localFileDropRequest: LocalFileDropRequest?
    @State private var isLocalFileDropTargeted = false
    @FocusState private var titleFieldFocused: Bool

    private var isFocused: Bool { workspace.focusedPaneID == pane.id }

    /// A pane accepts a drop when it is something a Workspace may hold, or an
    /// unfilled slot waiting to be filled. A chat, a form, or a manager page
    /// shows no preview and takes nothing — see `PaneKind.isCombinable`.
    ///
    /// This is the only place in the app where a Workspace is built, so both
    /// ends of the drag are checked here. The workspace strip used to check the source
    /// end for workspace drags; it no longer takes them at all.
    private var acceptsDrop: Bool {
        guard pane.isCombinable || pane.isEmptySlot else { return false }
        switch window.dragging {
        case .pane(let id):
            // Panes do not cross Workspaces — moving one elsewhere is "drop it
            // on the strip, then drag that workspace in". Only the front workspace is drawn,
            // so a foreign pane cannot reach here anyway; the guard says the
            // rule out loud instead of leaving it to be an accident of what
            // happens to be on screen. And a pane cannot land beside itself.
            return id != pane.id && workspace.layout.pane(id) != nil
        case .workspace(let id):
            // A Workspace cannot be folded into one of its own panes, and only
            // a Workspace of sessions and file browsers can be folded at all.
            // Keeping the content check here also protects this boundary if a
            // new dynamic Workspace kind is introduced later.
            guard id != workspace.id else { return false }
            return window.workspaces.first { $0.id == id }?.isCombinable ?? false
        case .assistantConversation:
            return false
        case nil:
            return false
        }
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
        .overlay { dropPreview }
        // The SSH terminal is an AppKit view. A drop destination installed on
        // this SwiftUI parent sits behind that native surface and never sees the
        // drag, so neither `dropEntered` nor the preview fires. Keep a dedicated
        // SwiftUI receiver above the pane and only let it participate in hit
        // testing while one of our own layout payloads is in flight.
        .overlay { layoutDropTarget }
        // This must be the outermost pane overlay. Both Ghostty and SwiftUI's
        // macOS Table install native AppKit views above their own SwiftUI
        // modifiers, so a child-level upload target never enters the drag
        // responder chain.
        .overlay { localFileDropTarget }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture {
            // Belt and braces for a drag released outside the window, where
            // no drop target of ours ever hears about it: the next click
            // anywhere in a pane puts the layout back.
            window.dragging = nil
            workspace.focus(pane.id)
        }
    }

    private var layoutDropTarget: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(.rect)
                .onDrop(
                    of: [.text],
                    delegate: PaneDropDelegate(
                        size: proxy.size,
                        isActive: window.dragging?.isLayoutPayload == true,
                        isEnabled: acceptsDrop,
                        replacesWhole: pane.isEmptySlot,
                        zone: $dropZone,
                        perform: perform,
                        cancel: { window.dragging = nil }
                    )
                )
                .allowsHitTesting(window.dragging?.isLayoutPayload == true)
        }
    }

    @ViewBuilder
    private var localFileDropTarget: some View {
        switch pane.content {
        case .sshSession, .sftpSession:
            NativeFileURLDropTarget(
                isTargeted: $isLocalFileDropTargeted,
                isEnabled: isActive && window.dragging == nil,
                receive: { urls in
                    guard !urls.isEmpty else { return false }
                    localFileDropRequest = LocalFileDropRequest(urls: urls)
                    return true
                }
            )
        case .empty:
            EmptyView()
        }
    }

    /// The preview is the *shape of the result* — the rectangle the dragged panes
    /// will occupy — rather than a hint that a drop is possible. Four edges a few
    /// pixels apart need a preview you can read without thinking.
    @ViewBuilder
    private var dropPreview: some View {
        if let dropZone {
            GeometryReader { proxy in
                let full = proxy.size
                let half = dropZone.previewRect(in: full)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
                    .frame(width: half.width, height: half.height)
                    .offset(x: half.minX, y: half.minY)
            }
            .allowsHitTesting(false)
        }
    }

    /// Four outcomes from one gesture: a whole workspace folded in beside this pane or
    /// into this slot, or a single pane moved to either. Which one is decided by
    /// what was picked up, not by where it landed.
    private func perform(_ zone: PaneDropZone) {
        let dragged = window.dragging
        switch dragged {
        case .workspace(let id) where id != workspace.id:
            if case .replace = zone {
                window.fill(pane.id, in: workspace.id, withPanesOf: id)
            } else if let placement = zone.placement {
                window.merge(
                    id, into: workspace.id, beside: pane.id,
                    axis: placement.axis, side: placement.side
                )
            }
        case .pane(let id) where id != pane.id:
            if case .replace = zone {
                window.movePane(id, into: pane.id)
            } else if let placement = zone.placement {
                window.movePane(
                    id, beside: pane.id,
                    axis: placement.axis, side: placement.side
                )
            }
        default:
            break
        }
        // Keep the source omitted from `displayedLayout` until the model move
        // is complete. Clearing first briefly mounts the same pane in both its
        // old and new parents, allowing a stale native-view update to win.
        window.dragging = nil
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .sshSession(let sshSession):
            TerminalPlaceholderView(
                sshSession: sshSession,
                workspace: workspace,
                isVisible: isActive,
                requestsFocus: isActive && isFocused && !window.isToolbarFindFocused,
                externalFileDrop: localFileDropRequest,
                isExternalFileDropTargeted: isLocalFileDropTargeted,
                closePane: { window.closePane(pane.id) }
            )
        case .sftpSession(let sftpSession):
            SFTPBrowserView(
                sftpSession: sftpSession,
                isPaneFocused: isActive && isFocused,
                focusPane: { workspace.focus(pane.id) },
                externalFileDrop: localFileDropRequest,
                isExternalFileDropTargeted: isLocalFileDropTargeted,
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
                SSHConnectionJourneyBackground(center: .bottomLeading)
            }
        } else if pane.kind == .sshSession {
            headerContent.background(terminalAppearance.background)
        } else if pane.kind == .sftpSession {
            headerContent.background(.background)
        } else {
            headerContent.termindGlassBar()
        }
    }

    private var presentsConnectionJourney: Bool {
        switch pane.content {
        case .sshSession(let session):
            session.connectionJourney.isPresented
        case .sftpSession(let session):
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
                TextField("Pane Name", text: $draftTitle)
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
            if isHovering {
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
                .help(Text("Close pane"))
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
            if isHovering {
                Button {
                    withAnimation(Motion.workspaceSwitch) { workspace.broadcastsInput.toggle() }
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
                .help(Text("Broadcast input to every SSH session in this workspace — ⌘B"))
                .accessibilityLabel(Text("Broadcast input"))
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
        let label = Text(pane.sidebarTitle(in: app.hostLibrary))
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
                .help(Text("Drag to move this pane, double-click to rename"))
                .onDrag {
                    window.dragging = .pane(pane.id)
                    return NSItemProvider(object: pane.id.uuidString as NSString)
                } preview: {
                    dragChip
                }
        } else if pane.kind.isRenameable {
            label
                .help(Text("Double-click to rename"))
        } else {
            // An unfilled slot is the only thing that reaches here, and it is
            // named after the state it is in — there is nothing to call it but
            // Empty, and it stops existing the moment something fills it.
            label
        }
    }

    private var dragChip: some View {
        Label {
            Text(pane.sidebarTitle(in: app.hostLibrary))
        } icon: {
            Image(systemName: pane.symbol)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.s)
        .termindGlassSurface(cornerRadius: Metrics.Radius.medium)
    }

    private func beginRename() {
        guard pane.kind.isRenameable else { return }
        draftTitle = pane.sidebarTitle(in: app.hostLibrary)
        isRenaming = true
        titleFieldFocused = true
    }

    private func commitRename() {
        window.rename(pane: pane.id, to: draftTitle)
        isRenaming = false
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var query = ""
    @State private var welcomeMessage = " "
    @FocusState private var isSearchFocused: Bool

    private var welcomeGreetings: [String] {
        [
            String(localized: "Hello, I'm Termind."),
            String(localized: "Your terminal, with judgment."),
            String(localized: "SSH and SFTP, with an assistant at hand."),
        ]
    }

    private var welcomePrompts: [String] {
        [
            String(localized: "What would you like to do?"),
            String(localized: "What do you feel like doing?"),
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
        .background(.background)
        .onAppear { isSearchFocused = true }
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

                if !accessibilityReduceMotion {
                    try? await Task.sleep(for: .milliseconds(120))
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
            text: $query, prompt: "Search hosts, or type user@host", density: .prominent
        )
        .focused($isSearchFocused)
        .onSubmit(submit)
    }

    private var matches: [Host] {
        query.isEmpty ? [] : app.hostLibrary.searchHosts(query)
    }

    /// An ad-hoc destination parsed from the field, offered only when nothing
    /// saved matches — a saved host is always the better answer, since it carries
    /// the key, the port, and the group.
    private var adHoc: QuickConnectTarget? {
        guard matches.isEmpty else { return nil }
        return app.parseQuickConnect(query)
    }

    /// Return connects to the best interpretation of what was typed, so the
    /// launcher can be driven without ever reaching for the mouse.
    private func submit() {
        if let host = matches.first {
            app.open(host, as: .sshSession, in: window)
        } else if let adHoc {
            app.openQuickConnect(adHoc, in: window)
        } else {
            return
        }
        query = ""
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Metrics.Space.l) {
            Button("Connect") { app.connect(in: window) }
            Button("Batch Startup") { app.batchStartup(in: window) }
            Button("New Chat") { window.openNewAssistantChat() }
        }
    }

    // MARK: - Results

    /// Recents when the field is empty, matches when it is not. One list in one
    /// place, so typing narrows what you were already looking at instead of
    /// replacing it with a different-looking panel.
    @ViewBuilder
    private var results: some View {
        if query.isEmpty {
            let hosts = app.recentHosts(limit: 6)
            if !hosts.isEmpty {
                section("Recents") {
                    ForEach(hosts) { host in
                        WelcomeHostRow(host: host)
                    }
                }
            }
        } else if let adHoc {
            section("Connect Once") {
                WelcomeQuickConnectRow(target: adHoc)
            }
        } else if matches.isEmpty {
            Text("No hosts match “\(query)”.")
                .foregroundStyle(.secondary)
        } else {
            section("Hosts") {
                ForEach(matches) { host in
                    WelcomeHostRow(host: host)
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// A host offered on the Welcome page. Click connects — the page exists to get
/// you onto a machine, and anything else is a right-click away.
private struct WelcomeHostRow: View {
    let host: Host

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        Button {
            app.open(host, as: .sshSession, in: window)
        } label: {
            HStack(spacing: Metrics.Space.m) {
                StatusDot(status: app.hostLibrary.status(of: host.id))
                Text(host.name)
                    .lineLimit(1)
                // Resolved through the store, so a quick-connect row that
                // matched a saved identity shows the login it will actually use.
                Text(app.hostLibrary.loginAddress(for: host))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Metrics.Space.m)
                trailing
            }
            .font(.callout)
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Metrics.Radius.medium))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            HostContextMenu(host: host)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let date = app.lastConnectedAt(for: host.id) {
            Text(date, format: .relative(presentation: .numeric))
                .foregroundStyle(.tertiary)
        }
    }
}

/// A parsed `user@host` that has not been persisted. Connect keeps it
/// transient; Save creates the Host (and username Identity) in one click.
private struct WelcomeQuickConnectRow: View {
    let target: QuickConnectTarget

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.loginAddress)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                Text("Not saved")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Metrics.Space.m)
            Button("Connect") {
                app.openQuickConnect(target, in: window)
            }
            Button("Save") {
                app.saveQuickConnect(target)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Metrics.Radius.medium))
    }
}

// MARK: - Dropping onto a pane

/// Where in a pane a drag is hovering, and therefore what letting go would do.
///
/// Four edge zones divided along the diagonals, so every point in the pane maps
/// to its nearest edge and there is no dead middle to hunt for. An empty pane is
/// the exception: it has nothing to sit beside, so the whole of it replaces.
enum PaneDropZone: Equatable {
    case leading
    case trailing
    case top
    case bottom
    /// The dragged panes take the slot outright — empty panes only.
    case replace

    var placement: (axis: SplitAxis, side: SplitSide)? {
        switch self {
        case .leading: (.horizontal, .before)
        case .trailing: (.horizontal, .after)
        case .top: (.vertical, .before)
        case .bottom: (.vertical, .after)
        case .replace: nil
        }
    }

    /// The half (or whole) the dragged panes will end up occupying.
    func previewRect(in size: CGSize) -> CGRect {
        switch self {
        case .leading: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .replace: CGRect(origin: .zero, size: size)
        }
    }
}

/// Tracks which edge a drag is nearest while it is over a pane.
///
/// A `DropDelegate` for the same reason `WorkspaceDropDelegate` is one: the preview has
/// to follow the pointer across four zones, and `dropDestination`'s `isTargeted`
/// is a single Bool that can only say whether a drop is possible at all.
private struct PaneDropDelegate: DropDelegate {
    let size: CGSize
    /// True only for one of Termind's own workspace or pane drags. Claiming arbitrary
    /// text drops here would make otherwise ordinary page content swallow them.
    let isActive: Bool
    /// False when this pane cannot take what is being dragged — a chat, a form,
    /// a manager page, or the dragged thing itself. No preview, no drop.
    let isEnabled: Bool
    /// True for an empty pane, which has nothing to sit beside.
    let replacesWhole: Bool
    @Binding var zone: PaneDropZone?
    let perform: (PaneDropZone) -> Void
    let cancel: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isActive && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        zone = isEnabled ? currentZone(info) : nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = isEnabled ? currentZone(info) : nil
        // Keep the internal drop active even when this particular pane cannot
        // split. A cancelled proposal may never receive `performDrop`, which is
        // precisely the callback needed to clear the source's transient state.
        // The absent preview and the no-op result still make the refusal clear.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
    }

    /// Reads what is being dragged from the model rather than the pasteboard —
    /// the payload would arrive after the drop is over. See `WindowModel.dragging`.
    func performDrop(info: DropInfo) -> Bool {
        let landed = currentZone(info)
        zone = nil
        guard isEnabled else {
            // An invalid inner target must still finish the internal drag. If it
            // simply rejects the drop, SwiftUI does not reliably offer it to the
            // root cancel target and the source workspace remains hidden indefinitely.
            cancel()
            return true
        }
        perform(landed)
        return true
    }

    private func currentZone(_ info: DropInfo) -> PaneDropZone {
        guard !replacesWhole else { return .replace }
        return Self.nearestEdge(to: info.location, in: size)
    }

    /// Nearest edge, decided by which side of the two diagonals the point falls
    /// on. Comparing normalised distances rather than absolute ones keeps the
    /// zones proportional, so a wide short pane does not end up almost entirely
    /// top-and-bottom.
    private static func nearestEdge(to point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .trailing }
        let x = point.x / size.width
        let y = point.y / size.height
        let fromLeading = x
        let fromTrailing = 1 - x
        let fromTop = y
        let fromBottom = 1 - y
        let nearest = min(fromLeading, fromTrailing, fromTop, fromBottom)
        return switch nearest {
        case fromLeading: .leading
        case fromTrailing: .trailing
        case fromTop: .top
        default: .bottom
        }
    }
}
