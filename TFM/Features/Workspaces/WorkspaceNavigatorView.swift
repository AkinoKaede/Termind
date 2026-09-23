import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation

/// The native source list for Vault and Workspaces.
/// Workspace layout drops clamp to insertion boundaries in the Workspace section.
struct WorkspaceNavigatorView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale

    @AppStorage(DesktopSettingsKey.vaultSectionExpanded) private var vaultExpanded = true
    @AppStorage(DesktopSettingsKey.workspaceSectionExpanded) private var workspaceExpanded = true

    @State private var workspaceFrames: [Workspace.ID: CGRect] = [:]
    @State private var workspaceHeaderFrame = CGRect.zero
    @State private var batchStartupFrame = CGRect.zero

    @State private var renamingWorkspaceID: Workspace.ID?
    @State private var workspaceRenameTitle = ""

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
                        title: AppStrings.Navigation.metrics, symbol: "waveform.path.ecg",
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
            .overlay { workspaceLayoutDropTarget }
            .modifier(WorkspaceNavigatorDragSession(window: window))
        }
        // `List` is backed by AppKit. A destination attached to the SwiftUI
        // ancestor sits behind its native rows and only wins sporadically as a
        // pane crosses from Ghostty into the sidebar. Put one receiver above the
        // list. It stays registered before AppKit starts its nested drag loop;
        // the receiver reads the window's drag state for each native callback.
        .onChange(of: window.selectedDestination) {
            switch window.selectedDestination {
            case .vault: vaultExpanded = true
            case .assistant, .settings, .metrics: break
            case .workspace: workspaceExpanded = true
            }
        }
        .onChange(of: window.vaultDestination) { vaultExpanded = true }
    }

    private var settingsSection: some View {
        Group {
            Text(AppStrings.Navigation.settings)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
                .padding(
                    .horizontal,
                    Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
                )
                .termindSidebarSectionLabel()

            SidebarNavigatorRow(
                title: AppStrings.Navigation.settings,
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
            navigatorSectionHeader(AppStrings.Navigation.vault, isExpanded: $vaultExpanded)

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
            navigatorSectionHeader(AppStrings.Navigation.workspaces, isExpanded: $workspaceExpanded)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    workspaceHeaderFrame = $0
                }

            if workspaceExpanded {
                if window.workspaces.isEmpty {
                    emptyRow(AppStrings.Workspace.noWorkspaces)
                }
                ForEach(window.workspaces) { workspace in
                    if renamingWorkspaceID == workspace.id {
                        workspaceRow(workspace)
                    } else if #available(macOS 26.0, *) {
                        // Keep the source outside measurement so List can read
                        // its drag trait and start a native row drag.
                        workspaceRow(workspace)
                            .draggable(workspace.id.uuidString) {
                                workspaceDragPreview(workspace)
                            }
                    } else {
                        workspaceRow(workspace)
                            .onDrag {
                                window.dragging = .workspace(workspace.id)
                                return NSItemProvider(object: workspace.id.uuidString as NSString)
                            } preview: {
                                workspaceDragPreview(workspace)
                            }
                    }
                }

                // The same container as the destinations above it. Drawn by
                // hand it sat 8pt further left than every other row and never
                // lit up under the pointer.
                SidebarNavigatorRow(title: AppStrings.Vault.batchStartup, symbol: MenuSymbol.batchStartup) {
                    workspaceExpanded = true
                    app.batchStartup(in: window)
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    batchStartupFrame = $0
                }
            }
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
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
            $0.frame(in: .global)
        } action: {
            workspaceFrames[workspace.id] = $0
        }
    }

    private func workspaceDragPreview(_ workspace: Workspace) -> some View {
        ItemDragPreview(title: workspace.title(in: app.hostLibrary, locale: locale), symbol: workspace.symbol)
    }

    private var draggedLayoutID: UUID? {
        guard window.sidebarMode == .navigation else { return nil }
        switch window.dragging {
        case .pane(let id), .workspace(let id): return id
        case .assistantConversation, nil: return nil
        }
    }

    private var workspaceDropBounds: CGRect {
        guard workspaceExpanded else { return workspaceHeaderFrame }
        let frames =
            [workspaceHeaderFrame, batchStartupFrame]
            + window.workspaces.compactMap { workspaceFrames[$0.id] }
        return frames.filter { !$0.isEmpty }.reduce(.null) { $0.union($1) }
    }

    private var workspaceLayoutDropTarget: some View {
        GeometryReader { proxy in
            // Native List cells do not inherit a named SwiftUI coordinate
            // space across their hosting boundary. Measure in global space,
            // then convert both the pointer and preview at the native overlay.
            let origin = proxy.frame(in: .global).origin
            WorkspaceLayoutDropTarget(
                draggedID: { draggedLayoutID },
                previewStyle: .insertion,
                preview: { point, _ in
                    let location = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
                    guard draggedLayoutID != nil, let proposal = dropProposal(at: location) else { return nil }
                    if !workspaceExpanded { workspaceExpanded = true }
                    return proposal.preview.offsetBy(dx: -origin.x, dy: -origin.y)
                },
                perform: { point, _ in
                    let location = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
                    guard draggedLayoutID != nil, let proposal = dropProposal(at: location) else { return false }
                    if !workspaceExpanded { workspaceExpanded = true }
                    switch window.dragging {
                    case .pane(let id): window.detachPane(id, at: proposal.target.insertionIndex)
                    case .workspace(let id): window.move(id, to: proposal.target.insertionIndex)
                    case .assistantConversation, nil: return false
                    }
                    window.dragging = nil
                    return true
                }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func dropProposal(at location: CGPoint) -> (target: WorkspaceSidebarDropTarget, preview: CGRect)? {
        guard !workspaceDropBounds.isNull, !workspaceDropBounds.isEmpty else { return nil }
        let visibleRows = window.workspaces.compactMap { workspace -> (Workspace.ID, CGRect)? in
            guard let frame = workspaceFrames[workspace.id], !frame.isEmpty else { return nil }
            return (workspace.id, frame)
        }
        let draggedRowIndex: Int?
        if case .workspace(let id)? = window.dragging {
            draggedRowIndex = visibleRows.firstIndex(where: { $0.0 == id })
        } else {
            draggedRowIndex = nil
        }
        let target = WorkspaceSidebarDropGeometry.target(
            rowFrames: visibleRows.map(\.1),
            draggedRowIndex: draggedRowIndex,
            pointerY: location.y
        )

        let frame: CGRect
        let boundaryY: CGFloat
        if let row = visibleRows.dropFirst(target.visibleBoundaryIndex).first {
            frame = row.1
            boundaryY = frame.minY
        } else if let row = visibleRows.last {
            frame = row.1
            boundaryY = frame.maxY
        } else if workspaceExpanded, !batchStartupFrame.isEmpty {
            frame = batchStartupFrame
            boundaryY = frame.minY
        } else {
            frame = workspaceHeaderFrame
            boundaryY = frame.maxY
        }
        guard !frame.isEmpty else { return nil }
        return (
            target,
            CGRect(x: frame.minX + 8, y: boundaryY - 1, width: max(0, frame.width - 16), height: 2)
        )
    }

    // MARK: - Shared rows and editing

    private func navigatorRow(
        title: LocalizedStringResource,
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
        _ title: LocalizedStringResource,
        isExpanded: Binding<Bool>
    ) -> some View {
        SidebarSectionHeader(title: title, isExpanded: isExpanded)
    }

    private func emptyRow(_ title: LocalizedStringResource) -> some View {
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
        workspaceRenameTitle = workspace.title(in: app.hostLibrary, locale: locale)
        renamingWorkspaceID = workspace.id
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

private struct WorkspaceNavigatorDragSession: ViewModifier {
    let window: WindowModel
    @Environment(AppModel.self) private var app
    @State private var cancellation = WorkspaceDragCancellationTracker()

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .dragConfiguration(
                    DragConfiguration(
                        operationsWithinApp: .init(allowMove: true),
                        operationsOutsideApp: .init(allowCopy: false)
                    )
                )
                .background {
                    WorkspaceNavigatorDragAnimation { session in
                        guard let value = session.draggingPasteboard.string(forType: .string),
                            let id = UUID(uuidString: value),
                            window.workspaces.contains(where: { $0.id == id })
                        else { return }
                        // An outside release becomes a new window. Configure the
                        // native session before AppKit starts any failed-drop animation.
                        session.animatesToStartingPositionsOnCancelOrFail = false
                    }
                }
                // Native List owns the session, so observe it here, not on a
                // row whose listener does not receive the native callbacks.
                .onDragSessionUpdated { session in
                    switch session.phase {
                    case .active:
                        // The preview-capable draggable API has no session
                        // item IDs. Its native pasteboard is ready at .active.
                        // List also queries payloads after ordinary clicks, so
                        // starting the preview must happen only in this phase.
                        guard let value = NSPasteboard(name: .drag).string(forType: .string),
                            let id = UUID(uuidString: value),
                            window.workspaces.contains(where: { $0.id == id })
                        else { return }
                        cancellation.begin()
                        window.dragging = .workspace(id)
                    case .ended(let operation):
                        let wasCancelled = cancellation.end()
                        if case .workspace(let id) = window.dragging,
                            operation == .cancel || operation == .forbidden,
                            WorkspaceLayoutDragCompletion.shouldTearOffAtCurrentPointer(
                                outside: app.mainWindows.frame(for: window), cancelled: wasCancelled
                            )
                        {
                            app.mainWindows.moveWorkspace(id, from: window, at: NSEvent.mouseLocation)
                        }
                        if case .workspace = window.dragging { window.dragging = nil }
                    default: break
                    }
                }
                .onDisappear { cancellation.end() }
        } else {
            content
        }
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

    var body: some View {
        row
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
                    prompt: String(localized: AppStrings.Workspace.workspaceName),
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
            .help(Text(AppStrings.Workspace.closeWorkspaceClickToCloseTheOthers))
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
                        ? AppStrings.Workspace.saveWorkspaceTemplate : AppStrings.Workspace.updateWorkspaceTemplate
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
                    title: localized(AppStrings.Common.rename),
                    symbol: MenuSymbol.rename,
                    action: onBeginRename
                )
            )
            if namedTitle != nil {
                entries.append(
                    NativeMenuEntry(
                        title: localized(AppStrings.Workspace.resetName), symbol: MenuSymbol.resetName
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
                    title: localized(AppStrings.Workspace.separatePanes), symbol: MenuSymbol.separatePanes
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
                        title: localized(AppStrings.Workspace.duplicateInNewWorkspace),
                        symbol: MenuSymbol.duplicate
                    ) {
                        act { window.duplicateSelectedInNewWorkspace() }
                    }
                )
            } else {
                entries.append(
                    NativeMenuEntry(
                        title: localized(AppStrings.Common.duplicate),
                        symbol: MenuSymbol.duplicate,
                        children: [
                            NativeMenuEntry(
                                title: localized(AppStrings.Workspace.inCurrentWorkspace),
                                symbol: MenuSymbol.currentWorkspace
                            ) {
                                act { window.duplicateSelected(axis: .horizontal) }
                            },
                            NativeMenuEntry(
                                title: localized(AppStrings.Workspace.inNewWorkspace),
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
                NativeMenuEntry(title: localized(AppStrings.Workspace.splitRight), symbol: MenuSymbol.splitRight) {
                    act { window.splitSelected(axis: .horizontal) }
                }
            )
            entries.append(
                NativeMenuEntry(title: localized(AppStrings.Workspace.splitDown), symbol: MenuSymbol.splitDown) {
                    act { window.splitSelected(axis: .vertical) }
                }
            )
            entries.append(.separator)
        }
        entries.append(
            NativeMenuEntry(
                title: localized(AppStrings.Workspace.moveWorkspaceToNewWindow), symbol: MenuSymbol.moveToNewWindow
            ) {
                app.mainWindows.moveWorkspace(workspace.id, from: window)
            }
        )
        entries.append(.separator)
        // Close Other and Close All are the same verb as the item above them,
        // so only the first of the run carries a glyph.
        entries.append(
            NativeMenuEntry(
                title: localized(AppStrings.Workspace.closeWorkspace), symbol: MenuSymbol.closeWorkspace
            ) {
                window.close(workspace.id)
            }
        )
        entries.append(
            NativeMenuEntry(title: localized(AppStrings.Workspace.closeOtherWorkspaces)) {
                window.closeOthers(than: workspace.id)
            }
        )
        entries.append(
            NativeMenuEntry(title: localized(AppStrings.Workspace.closeAllWorkspaces)) {
                window.closeAll()
            }
        )
        return entries
    }

    private var namedTitle: String? {
        workspace.isSplit ? workspace.customTitle : workspace.focusedPane.customTitle
    }

    private func localized(_ key: LocalizedStringResource) -> String {
        AppLocalization.resolve(key, locale: locale)
    }

    private func act(_ action: () -> Void) {
        window.select(workspace.id)
        action()
    }
}
