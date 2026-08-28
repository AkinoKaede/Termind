import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The native source list for Vault and Workspaces.
/// Workspace layout drops are accepted only inside the Workspace section.
struct WorkspaceNavigatorView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @AppStorage(SettingsKey.vaultSectionExpanded) private var vaultExpanded = true
    @AppStorage(SettingsKey.workspaceSectionExpanded) private var workspaceExpanded = true

    @State private var workspaceDropTarget: WorkspaceSidebarDropTarget?
    @State private var workspaceFrames: [Workspace.ID: CGRect] = [:]
    @State private var workspaceHeaderFrame = CGRect.zero
    @State private var batchStartupFrame = CGRect.zero

    @State private var renamingWorkspaceID: Workspace.ID?
    @State private var workspaceRenameTitle = ""

    nonisolated private static let coordinateSpace = "termind.workspaceNavigator"

    var body: some View {
        List {
            welcomeRow
            vaultSection
            workspaceSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .coordinateSpace(.named(Self.coordinateSpace))
        // `List` is backed by AppKit. A destination attached to the SwiftUI
        // ancestor sits behind its native rows and only wins sporadically as a
        // pane crosses from Ghostty into the sidebar. Put one receiver above the
        // complete Workspace section while an internal layout drag is active.
        .overlay { workspaceLayoutDropTarget }
        .onChange(of: window.selectedDestination) {
            switch window.selectedDestination {
            case .vault: vaultExpanded = true
            case .assistant: break
            case .workspace: workspaceExpanded = true
            }
        }
        .onChange(of: window.vaultDestination) { vaultExpanded = true }
        .onChange(of: window.dragging) {
            if window.dragging?.isLayoutPayload != true { workspaceDropTarget = nil }
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
        Section(isExpanded: $vaultExpanded) {
            ForEach(VaultPage.allCases.filter { $0 != .welcome }) { page in
                navigatorRow(
                    title: page.label,
                    symbol: page.symbol,
                    count: count(for: page),
                    isSelected: window.selectedDestination == .vault
                        && window.vaultDestination.page == page
                ) {
                    window.dragging = nil
                    vaultExpanded = true
                    window.openPage(page)
                }
            }
        } header: {
            sectionHeader("Vault")
        }
    }

    private func count(for page: VaultPage) -> Int {
        switch page {
        case .welcome: 0
        case .hosts: app.hostLibrary.hosts.count
        case .keychain: app.hostLibrary.keys.count + app.hostLibrary.identities.count
        case .snippets: app.hostLibrary.snippets.count
        }
    }

    // MARK: - Workspaces

    private var workspaceSection: some View {
        Section(isExpanded: $workspaceExpanded) {
            if window.workspaces.isEmpty {
                emptyRow("No Workspaces")
            }
            ForEach(Array(window.workspaces.enumerated()), id: \.element.id) { index, workspace in
                WorkspaceNavigatorRow(
                    workspace: workspace,
                    isSelected: window.selectedWorkspaceID == workspace.id,
                    isRenaming: renamingWorkspaceID == workspace.id,
                    renameTitle: $workspaceRenameTitle,
                    onBeginRename: { beginWorkspaceRename(workspace) },
                    onCommitRename: { commitWorkspaceRename(workspace) },
                    onCancelRename: cancelWorkspaceRename
                )
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.coordinateSpace))
                } action: { workspaceFrames[workspace.id] = $0 }
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
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Button {
                workspaceExpanded = true
                app.batchStartup(in: window)
            } label: {
                Label("Batch Startup", systemImage: "wind")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Metrics.Sidebar.navigationRowHeight)
                    .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                if window.workspaces.isEmpty, workspaceDropTarget != nil {
                    workspaceInsertionLine
                }
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { batchStartupFrame = $0 }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            sectionHeader("Workspace")
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { workspaceHeaderFrame = $0 }
        }
    }

    private var draggedWorkspaceID: Workspace.ID? {
        guard case .workspace(let id)? = window.dragging else { return nil }
        return id
    }

    private var workspaceDropBounds: CGRect {
        guard workspaceExpanded else { return workspaceHeaderFrame }
        let frames = [workspaceHeaderFrame, batchStartupFrame]
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
        Button(action: action) {
            HStack(spacing: Metrics.Space.s) {
                Label(title, systemImage: symbol)
                Spacer(minLength: Metrics.Space.xs)
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.Sidebar.navigationRowHeight)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .contentShape(.rect)
            .termindSidebarRowBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        sectionHeader(title) { EmptyView() }
    }

    private func sectionHeader<Actions: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Text(title)
            Spacer(minLength: 0)
            actions()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyRow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.Sidebar.navigationRowHeight)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    private func beginWorkspaceRename(_ workspace: Workspace) {
        guard workspace.isRenameable else { return }
        renamingWorkspaceID = workspace.id
        workspaceRenameTitle = workspace.title(in: app.hostLibrary)
    }

    private func commitWorkspaceRename(_ workspace: Workspace) {
        window.rename(workspace.id, to: workspaceRenameTitle)
        cancelWorkspaceRename()
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
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: workspace.symbol)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: Metrics.Sidebar.rowIcon)

            if isRenaming {
                TextField("Workspace Name", text: $renameTitle)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title(in: app.hostLibrary))
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
        .termindSidebarRowBackground(isSelected: isSelected)
        .onTapGesture {
            guard !isRenaming else { return }
            window.dragging = nil
            window.select(workspace.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onBeginRename))
        .onHover { hovering = $0 }
        .onDrag {
            window.dragging = .workspace(workspace.id)
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .contextMenu { contextMenu }
        .help(Text(workspace.title(in: app.hostLibrary)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(workspace.title(in: app.hostLibrary)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .onChange(of: isRenaming, initial: true) {
            if isRenaming { DispatchQueue.main.async { titleFocused = true } }
        }
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

    @ViewBuilder
    private var contextMenu: some View {
        if workspace.isRenameable {
            Button("Rename", action: onBeginRename)
            if namedTitle != nil {
                Button("Reset Name") { window.rename(workspace.id, to: "") }
            }
            Divider()
        }
        if workspace.isCombinable {
            if workspace.isSplit {
                Button("Duplicate in New Workspace") {
                    act { window.duplicateSelectedInNewWorkspace() }
                }
            } else {
                Menu("Duplicate") {
                    Button("In Current Workspace") {
                        act { window.duplicateSelected(axis: .horizontal) }
                    }
                    Button("In New Workspace") {
                        act { window.duplicateSelectedInNewWorkspace() }
                    }
                }
            }
            Divider()
            Button("Split Right") { act { window.splitSelected(axis: .horizontal) } }
            Button("Split Down") { act { window.splitSelected(axis: .vertical) } }
            Divider()
        }
        Button("Close Workspace") { window.close(workspace.id) }
        Button("Close Other Workspaces") { window.closeOthers(than: workspace.id) }
        Button("Close All Workspaces") { window.closeAll() }
    }

    private var namedTitle: String? {
        workspace.isSplit ? workspace.customTitle : workspace.focusedPane.customTitle
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
