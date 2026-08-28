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

    @State private var ghostIndex: Int?
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
        .onDrop(
            of: [.text],
            delegate: WorkspaceNavigatorDropDelegate(
                window: window,
                contains: { workspaceDropBounds.contains($0) },
                index: insertionIndex,
                expand: { workspaceExpanded = true },
                ghostIndex: $ghostIndex
            )
        )
        .onChange(of: window.selectedDestination) {
            switch window.selectedDestination {
            case .vault: vaultExpanded = true
            case .assistant: break
            case .workspace: workspaceExpanded = true
            }
        }
        .onChange(of: window.vaultDestination) { vaultExpanded = true }
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
            ForEach(window.workspaces) { workspace in
                let displayedIndex = displayedWorkspaces.firstIndex { $0.id == workspace.id }
                if let displayedIndex, ghostIndex == displayedIndex {
                    workspaceGhost
                }

                WorkspaceNavigatorRow(
                    workspace: workspace,
                    isSelected: window.selectedWorkspaceID == workspace.id,
                    isDragged: draggedWorkspaceID == workspace.id,
                    isRenaming: renamingWorkspaceID == workspace.id,
                    renameTitle: $workspaceRenameTitle,
                    onBeginRename: { beginWorkspaceRename(workspace) },
                    onCommitRename: { commitWorkspaceRename(workspace) },
                    onCancelRename: cancelWorkspaceRename
                )
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.coordinateSpace))
                } action: { workspaceFrames[workspace.id] = $0 }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if ghostIndex == displayedWorkspaces.count {
                workspaceGhost
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
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { batchStartupFrame = $0 }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            sectionHeader("Workspace") {
                Button {
                    workspaceExpanded = true
                    app.connect(in: window)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(Text("New Workspace"))
                .accessibilityLabel(Text("New Workspace"))
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { workspaceHeaderFrame = $0 }
        }
    }

    private var displayedWorkspaces: [Workspace] {
        guard let draggedWorkspaceID else { return window.workspaces }
        return window.workspaces.filter { $0.id != draggedWorkspaceID }
    }

    private var draggedWorkspaceID: Workspace.ID? {
        guard case .workspace(let id)? = window.dragging else { return nil }
        return id
    }

    private var workspaceDropBounds: CGRect {
        guard workspaceExpanded else { return workspaceHeaderFrame }
        let frames = [workspaceHeaderFrame, batchStartupFrame]
            + displayedWorkspaces.compactMap { workspaceFrames[$0.id] }
        return frames.filter { !$0.isEmpty }.reduce(.null) { $0.union($1) }
    }

    private func insertionIndex(at location: CGPoint) -> Int {
        WorkspaceSidebarDropGeometry.insertionIndex(
            rowFrames: displayedWorkspaces.compactMap { workspaceFrames[$0.id] },
            pointerY: location.y
        )
    }

    @ViewBuilder
    private var workspaceGhost: some View {
        if let identity = draggedIdentity {
            Label(identity.title, systemImage: identity.symbol)
                .lineLimit(1)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.Sidebar.workspaceRowHeight)
                .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
                .background(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.Sidebar.rowCornerRadius)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                }
                .allowsHitTesting(false)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .transition(.opacity)
        }
    }

    private var draggedIdentity: (symbol: String, title: String)? {
        switch window.dragging {
        case .pane(let id):
            guard let pane = window.pane(id) else { return nil }
            return (pane.symbol, pane.sidebarTitle(in: app.hostLibrary))
        case .workspace(let id):
            guard let workspace = window.workspaces.first(where: { $0.id == id }) else {
                return nil
            }
            return (workspace.symbol, workspace.title(in: app.hostLibrary))
        case nil:
            return nil
        }
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

nonisolated enum WorkspaceSidebarDropGeometry {
    static func insertionIndex(rowFrames: [CGRect], pointerY: CGFloat) -> Int {
        rowFrames.reduce(into: 0) { index, frame in
            if frame.midY < pointerY { index += 1 }
        }
    }
}

private struct WorkspaceNavigatorRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isDragged: Bool
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
        .frame(height: isDragged ? 0 : Metrics.Sidebar.workspaceRowHeight)
        .opacity(isDragged ? 0 : 1)
        .clipped()
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

private struct WorkspaceNavigatorDropDelegate: DropDelegate {
    let window: WindowModel
    let contains: (CGPoint) -> Bool
    let index: (CGPoint) -> Int
    let expand: () -> Void
    @Binding var ghostIndex: Int?

    func validateDrop(info: DropInfo) -> Bool {
        window.dragging?.isLayoutPayload == true && contains(info.location)
    }

    func dropEntered(info: DropInfo) {
        guard contains(info.location) else { return }
        expand()
        ghostIndex = index(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard contains(info.location) else {
            ghostIndex = nil
            return DropProposal(operation: .cancel)
        }
        expand()
        ghostIndex = index(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        ghostIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard contains(info.location) else { return false }
        let landed = index(info.location)
        ghostIndex = nil
        switch window.dragging {
        case .pane(let id): window.detachPane(id, at: landed)
        case .workspace(let id): window.move(id, to: landed)
        case nil: return false
        }
        window.dragging = nil
        return true
    }
}
