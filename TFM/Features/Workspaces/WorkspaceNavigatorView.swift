import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation
import UniformTypeIdentifiers

/// The native source list for Vault and Workspaces.
/// Workspace layout drops are accepted only inside the Workspace section.
struct WorkspaceNavigatorView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale

    @AppStorage(DesktopSettingsKey.vaultSectionExpanded) private var vaultExpanded = true
    @AppStorage(DesktopSettingsKey.workspaceSectionExpanded) private var workspaceExpanded = true

    @State private var workspaceDropTarget: WorkspaceSidebarDropTarget?
    @State private var workspaceFrames: [Workspace.ID: CGRect] = [:]
    @State private var workspaceHeaderFrame = CGRect.zero
    @State private var batchStartupFrame = CGRect.zero

    @State private var renamingWorkspaceID: Workspace.ID?
    @State private var workspaceRenameTitle = ""

    nonisolated private static let coordinateSpace = "termind.workspaceNavigator"

    var body: some View {
        VStack(spacing: 0) {
            List {
                // Applied once here rather than on each row: the rows are shared
                // with the ListViewKit-backed modes, which have no list of their
                // own to inset, and the one rendered edge everything lines up on is
                // `Metrics.Sidebar.rowHorizontalMargin` inside the row itself.
                Group {
                    welcomeRow
                    SidebarNavigatorRow(
                        title: "Metrics", symbol: "waveform.path.ecg",
                        isSelected: window.selectedDestination == .metrics
                    ) {
                        window.dragging = nil
                        window.selectedDestination = .metrics
                    }
                    vaultSection
                    workspaceSection
                    settingsSection
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .coordinateSpace(.named(Self.coordinateSpace))
            .overlay { workspaceLayoutDropTarget }

        }
        // `List` is backed by AppKit. A destination attached to the SwiftUI
        // ancestor sits behind its native rows and only wins sporadically as a
        // pane crosses from Ghostty into the sidebar. Put one receiver above the
        // complete Workspace section while an internal layout drag is active.
        .onChange(of: window.selectedDestination) {
            switch window.selectedDestination {
            case .vault: vaultExpanded = true
            case .assistant, .settings, .metrics: break
            case .workspace: workspaceExpanded = true
            }
        }
        .onChange(of: window.vaultDestination) { vaultExpanded = true }
        .onChange(of: window.dragging) {
            if window.dragging?.isLayoutPayload != true { workspaceDropTarget = nil }
        }
    }

    private var settingsSection: some View {
        Group {
            Text("Settings")
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
                .padding(
                    .horizontal,
                    Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
                )
                .termindSidebarSectionLabel()

            SidebarNavigatorRow(
                title: "Settings",
                symbol: "gearshape",
                isSelected: window.selectedDestination == .settings
            ) {
                window.dragging = nil
                window.openSettings()
            }
        }
    }

    // MARK: - Vault

    private var welcomeRow: some View {
        navigatorRow(
            title: VaultPage.welcome.label,
            symbol: VaultPage.welcome.symbol,
            count: 0,
            isSelected: window.selectedDestination == .vault
                && window.vaultDestination.page == .welcome
        ) {
            window.dragging = nil
            window.openPage(.welcome)
        }
    }

    private var vaultSection: some View {
        Group {
            navigatorSectionHeader("Vault", isExpanded: $vaultExpanded)

            if vaultExpanded {
                ForEach(VaultPage.allCases.filter { $0 != .welcome }) { page in
                    SidebarNavigatorRow(
                        title: page.label,
                        symbol: page.symbol,
                        count: count(for: page),
                        isSelected: window.selectedDestination == .vault
                            && window.vaultDestination.page == page,
                        // The page's own New verbs, so adding a host does not
                        // require visiting Hosts first.
                        menu: { window.creationMenu(for: page, locale: locale) }
                    ) {
                        window.dragging = nil
                        vaultExpanded = true
                        window.openPage(page)
                    }
                }
            }
        }
    }

    private func count(for page: VaultPage) -> Int {
        switch page {
        case .welcome: 0
        case .hosts: app.hostLibrary.hosts.count
        case .keychain: app.hostLibrary.keys.count + app.hostLibrary.reusableIdentities.count
        case .portForwarding: app.forwardings.rules.count
        case .snippets: app.hostLibrary.snippets.count
        case .knownHosts: app.knownHosts.entries.count
        }
    }

    // MARK: - Workspaces

    private var workspaceSection: some View {
        Group {
            navigatorSectionHeader("Workspaces", isExpanded: $workspaceExpanded)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.coordinateSpace))
                } action: {
                    workspaceHeaderFrame = $0
                }

            if workspaceExpanded {
                if window.workspaces.isEmpty {
                    emptyRow("No Workspaces")
                }
                ForEach(Array(window.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    WorkspaceNavigatorRow(
                        workspace: workspace,
                        isSelected: window.displayedWorkspace?.id == workspace.id,
                        isRenaming: renamingWorkspaceID == workspace.id,
                        renameTitle: $workspaceRenameTitle,
                        onBeginRename: { beginWorkspaceRename(workspace) },
                        onCommitRename: { commitWorkspaceRename(workspace) },
                        onCancelRename: cancelWorkspaceRename
                    )
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(Self.coordinateSpace))
                    } action: {
                        workspaceFrames[workspace.id] = $0
                    }
                    .overlay(alignment: .top) {
                        if workspaceDropTarget?.visibleBoundaryIndex == index {
                            workspaceInsertionLine
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if index == window.workspaces.indices.last,
                            workspaceDropTarget?.visibleBoundaryIndex == window.workspaces.count
                        {
                            workspaceInsertionLine
                        }
                    }
                }

                // The same container as the destinations above it. Drawn by
                // hand it sat 8pt further left than every other row and never
                // lit up under the pointer.
                SidebarNavigatorRow(title: "Batch Startup", symbol: MenuSymbol.batchStartup) {
                    workspaceExpanded = true
                    app.batchStartup(in: window)
                }
                .overlay(alignment: .top) {
                    if window.workspaces.isEmpty, workspaceDropTarget != nil {
                        workspaceInsertionLine
                    }
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.coordinateSpace))
                } action: {
                    batchStartupFrame = $0
                }
            }
        }
    }

    private var draggedWorkspaceID: Workspace.ID? {
        guard case .workspace(let id)? = window.dragging else { return nil }
        return id
    }

    private var workspaceDropBounds: CGRect {
        guard workspaceExpanded else { return workspaceHeaderFrame }
        let frames =
            [workspaceHeaderFrame, batchStartupFrame]
            + window.workspaces.compactMap { workspaceFrames[$0.id] }
        return frames.filter { !$0.isEmpty }.reduce(.null) { $0.union($1) }
    }

    @ViewBuilder
    private var workspaceLayoutDropTarget: some View {
        if window.dragging?.isLayoutPayload == true,
            !workspaceDropBounds.isNull, !workspaceDropBounds.isEmpty
        {
            GeometryReader { proxy in
                WorkspaceNavigatorDropReceiver(
                    onLocation: { point in
                        guard window.dragging?.isLayoutPayload == true else {
                            workspaceDropTarget = nil
                            return false
                        }
                        workspaceExpanded = true
                        workspaceDropTarget = dropTarget(at: point)
                        return workspaceDropTarget != nil
                    },
                    onExit: { workspaceDropTarget = nil },
                    onDrop: { point in
                        guard window.dragging?.isLayoutPayload == true,
                            let target = dropTarget(at: point)
                        else {
                            workspaceDropTarget = nil
                            return false
                        }
                        workspaceDropTarget = nil
                        switch window.dragging {
                        case .pane(let id): window.detachPane(id, at: target.insertionIndex)
                        case .workspace(let id): window.move(id, to: target.insertionIndex)
                        case .assistantConversation, nil: return false
                        }
                        window.dragging = nil
                        return true
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .allowsHitTesting(true)
        }
    }

    private func dropTarget(at location: CGPoint) -> WorkspaceSidebarDropTarget? {
        let visibleRows = window.workspaces.compactMap { workspace -> (Workspace.ID, CGRect)? in
            guard let frame = workspaceFrames[workspace.id] else { return nil }
            return (workspace.id, frame)
        }
        let draggedRowIndex = draggedWorkspaceID.flatMap { draggedID in
            visibleRows.firstIndex(where: { $0.0 == draggedID })
        }
        return WorkspaceSidebarDropGeometry.target(
            rowFrames: visibleRows.map(\.1),
            draggedRowIndex: draggedRowIndex,
            pointerY: location.y
        )
    }

    private var workspaceInsertionLine: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }

    // MARK: - Shared rows and editing

    private func navigatorRow(
        title: LocalizedStringKey,
        symbol: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SidebarNavigatorRow(
            title: title, symbol: symbol, count: count,
            isSelected: isSelected, action: action
        )
    }

    private func navigatorSectionHeader(
        _ title: LocalizedStringKey,
        isExpanded: Binding<Bool>
    ) -> some View {
        SidebarSectionHeader(title: title, isExpanded: isExpanded)
    }

    private func emptyRow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.Sidebar.navigationRowHeight)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            // The same breathing edge the rows around it carry, so "No
            // Workspaces" starts where a workspace name would.
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalMargin)
    }

    private func beginWorkspaceRename(_ workspace: Workspace) {
        guard workspace.isRenameable else { return }
        renamingWorkspaceID = workspace.id
        workspaceRenameTitle = workspace.title(in: app.hostLibrary, locale: locale)
    }

    private func commitWorkspaceRename(_ workspace: Workspace) {
        guard renamingWorkspaceID == workspace.id else { return }
        let title = workspaceRenameTitle
        cancelWorkspaceRename()
        window.rename(workspace.id, to: title)
    }

    private func cancelWorkspaceRename() {
        renamingWorkspaceID = nil
        workspaceRenameTitle = ""
    }

}

nonisolated struct WorkspaceSidebarDropTarget: Equatable, Sendable {
    let insertionIndex: Int
    let visibleBoundaryIndex: Int
}

nonisolated enum WorkspaceSidebarDropGeometry {
    static func target(
        rowFrames: [CGRect],
        draggedRowIndex: Int?,
        pointerY: CGFloat
    ) -> WorkspaceSidebarDropTarget {
        let visibleBoundaryIndex = insertionIndex(rowFrames: rowFrames, pointerY: pointerY)
        let insertionFrames = rowFrames.enumerated().compactMap { index, frame in
            index == draggedRowIndex ? nil : frame
        }
        return WorkspaceSidebarDropTarget(
            insertionIndex: insertionIndex(rowFrames: insertionFrames, pointerY: pointerY),
            visibleBoundaryIndex: visibleBoundaryIndex
        )
    }

    static func insertionIndex(rowFrames: [CGRect], pointerY: CGFloat) -> Int {
        rowFrames.reduce(into: 0) { index, frame in
            if frame.midY < pointerY { index += 1 }
        }
    }
}

private struct WorkspaceNavigatorRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameTitle: String
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.locale) private var locale
    @State private var hovering = false

    @ViewBuilder
    var body: some View {
        if isRenaming {
            row
        } else {
            row.onDrag {
                window.dragging = .workspace(workspace.id)
                return NSItemProvider(object: workspace.id.uuidString as NSString)
            }
        }
    }

    private var row: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: workspace.symbol)
                .foregroundStyle(
                    SidebarSelectionStyle.iconForeground(
                        isSelected: isSelected,
                        controlActiveState: controlActiveState
                    )
                )
                .frame(width: Metrics.Sidebar.rowIcon)

            if isRenaming {
                SidebarInlineRenameField(
                    text: $renameTitle,
                    prompt: String(localized: "Workspace Name"),
                    isSelected: isSelected,
                    controlActiveState: controlActiveState,
                    onSubmit: onCommitRename,
                    onCancel: onCancelRename
                ).singleLinePaste()
                    .frame(height: 18)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title(in: app.hostLibrary, locale: locale))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    if let subtitle = workspace.subtitle(in: app.hostLibrary) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }

            Spacer(minLength: 0)
            trailingControl
        }
        .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.Sidebar.workspaceRowHeight)
        .contentShape(.rect)
        .termindSidebarRow(isSelected: isSelected) { contextMenu }
        .onTapGesture {
            window.dragging = nil
            window.select(workspace.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onBeginRename))
        .onHover { hovering = $0 }
        // Match Assistant's inline rename treatment: the row itself must not
        // draw a second keyboard-focus rectangle around the plain field.
        .focusable(false)
        .focusEffectDisabled()
        .help(Text(workspace.title(in: app.hostLibrary, locale: locale)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(workspace.title(in: app.hostLibrary, locale: locale))
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if hovering, !isRenaming {
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    window.closeOthers(than: workspace.id)
                } else {
                    window.close(workspace.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help(Text("Close Workspace — ⌥-click to close the others"))
        } else if workspace.status != .disconnected || workspace.hasUnreadOutput {
            StatusDot(status: workspace.status, hasUnread: workspace.hasUnreadOutput, size: 6)
                .frame(width: 14)
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private var contextMenu: [NativeMenuEntry] {
        var entries: [NativeMenuEntry] = []
        entries.append(
            NativeMenuEntry(
                title: localized(
                    workspace.sourceTemplateID == nil
                        ? "Save Workspace Template" : "Update Workspace Template"
                ),
                symbol: "square.and.arrow.down",
                isEnabled: workspace.workspaceTemplateLayout(in: app.hostLibrary) != nil
            ) {
                act { window.requestSaveWorkspaceTemplate(workspace.id) }
            }
        )
        entries.append(.separator)
        if workspace.isRenameable {
            entries.append(
                NativeMenuEntry(
                    title: localized("Rename"),
                    symbol: MenuSymbol.rename,
                    action: onBeginRename
                )
            )
            if namedTitle != nil {
                entries.append(
                    NativeMenuEntry(
                        title: localized("Reset Name"), symbol: MenuSymbol.resetName
                    ) {
                        window.rename(workspace.id, to: "")
                    }
                )
            }
            entries.append(.separator)
        }
        // Only a merged Workspace can be taken apart, and taking it apart is
        // the only way back — the last pane cannot be dragged out to the
        // Navigator, because a pane alone in its Workspace has nothing to
        // detach from.
        if workspace.isSplit {
            entries.append(
                NativeMenuEntry(
                    title: localized("Separate Panes"), symbol: MenuSymbol.separatePanes
                ) {
                    window.separatePanes(in: workspace.id)
                }
            )
            entries.append(.separator)
        }
        if workspace.isCombinable {
            if workspace.isSplit {
                entries.append(
                    NativeMenuEntry(
                        title: localized("Duplicate in New Workspace"),
                        symbol: MenuSymbol.duplicate
                    ) {
                        act { window.duplicateSelectedInNewWorkspace() }
                    }
                )
            } else {
                entries.append(
                    NativeMenuEntry(
                        title: localized("Duplicate"),
                        symbol: MenuSymbol.duplicate,
                        children: [
                            NativeMenuEntry(
                                title: localized("in Current Workspace"),
                                symbol: MenuSymbol.currentWorkspace
                            ) {
                                act { window.duplicateSelected(axis: .horizontal) }
                            },
                            NativeMenuEntry(
                                title: localized("in New Workspace"),
                                symbol: MenuSymbol.newWorkspace
                            ) {
                                act { window.duplicateSelectedInNewWorkspace() }
                            },
                        ]
                    )
                )
            }
            entries.append(.separator)
            entries.append(
                NativeMenuEntry(title: localized("Split Right"), symbol: MenuSymbol.splitRight) {
                    act { window.splitSelected(axis: .horizontal) }
                }
            )
            entries.append(
                NativeMenuEntry(title: localized("Split Down"), symbol: MenuSymbol.splitDown) {
                    act { window.splitSelected(axis: .vertical) }
                }
            )
            entries.append(.separator)
        }
        entries.append(
            NativeMenuEntry(title: localized("Move Workspace to New Window"), symbol: MenuSymbol.moveToNewWindow) {
                app.mainWindows.moveWorkspace(workspace.id, from: window)
            }
        )
        entries.append(.separator)
        // Close Other and Close All are the same verb as the item above them,
        // so only the first of the run carries a glyph.
        entries.append(
            NativeMenuEntry(
                title: localized("Close Workspace"), symbol: MenuSymbol.closeWorkspace
            ) {
                window.close(workspace.id)
            }
        )
        entries.append(
            NativeMenuEntry(title: localized("Close Other Workspaces")) {
                window.closeOthers(than: workspace.id)
            }
        )
        entries.append(
            NativeMenuEntry(title: localized("Close All Workspaces")) {
                window.closeAll()
            }
        )
        return entries
    }

    private var namedTitle: String? {
        workspace.isSplit ? workspace.customTitle : workspace.focusedPane.customTitle
    }

    private func localized(_ key: String.LocalizationValue) -> String {
        AppLocalization.string(key, locale: locale)
    }

    private func act(_ action: () -> Void) {
        window.select(workspace.id)
        action()
    }
}

private struct WorkspaceNavigatorDropReceiver: NSViewRepresentable {
    let onLocation: (CGPoint) -> Bool
    let onExit: () -> Void
    let onDrop: (CGPoint) -> Bool

    func makeNSView(context _: Context) -> WorkspaceNavigatorDropReceivingView {
        WorkspaceNavigatorDropReceivingView()
    }

    func updateNSView(_ view: WorkspaceNavigatorDropReceivingView, context _: Context) {
        view.onLocation = onLocation
        view.onExit = onExit
        view.onDrop = onDrop
    }
}

@MainActor
private final class WorkspaceNavigatorDropReceivingView: NSView {
    var onLocation: (CGPoint) -> Bool = { _ in false }
    var onExit: () -> Void = {}
    var onDrop: (CGPoint) -> Bool = { _ in false }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender) ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender) ? .move : []
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        onExit()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let accepted = onDrop(location(of: sender))
        onExit()
        return accepted
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onExit()
        super.concludeDragOperation(sender)
    }

    private func update(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.availableType(from: [.string]) != nil else {
            onExit()
            return false
        }
        return onLocation(location(of: sender))
    }

    private func location(of sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

}
