import AppKit
import ListViewKit
import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// The window's one left-hand column. A glass mode rail switches the Navigator
/// and three Workspace tools in place without the square selection segments of
/// `NSSegmentedControl`.
struct WindowSidebarView: View {

    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            modeSelector
                .padding(.horizontal, Metrics.Space.m)
                .padding(.vertical, Metrics.Space.s)
            sidebarContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: focusedPaneID, initial: true) {
            window.reconcileSidebarMode()
        }
        .onChange(of: window.selectedDestination, initial: true) {
            window.reconcileSidebarMode()
        }
    }

    private var focusedPaneID: Pane.ID? { window.selectedWorkspace?.focusedPaneID }

    @ViewBuilder
    private var modeSelector: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: Metrics.Space.xs) {
                    modeButtons(usesSystemGlass: true)
                }
                .padding(Metrics.Space.xs)
                .glassEffect(.regular, in: .capsule)
            } else {
                modeButtons(usesSystemGlass: false)
                    .padding(Metrics.Space.xs)
                    .termindGlassCapsule()
            }
        }
        .animation(reduceMotion ? nil : Motion.panel, value: window.sidebarMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sidebar"))
    }

    private func modeButtons(usesSystemGlass: Bool) -> some View {
        HStack(spacing: Metrics.Space.xs) {
            ForEach(Array(WindowSidebarState.Mode.allCases.enumerated()), id: \.element.id) {
                index, mode in
                if index > 0 {
                    Divider()
                        .frame(height: 18)
                        .opacity(0.55)
                }
                modeButton(mode, usesSystemGlass: usesSystemGlass)
            }
        }
    }

    private func modeButton(
        _ mode: WindowSidebarState.Mode,
        usesSystemGlass: Bool
    ) -> some View {
        let isSelected = window.sidebarMode == mode
        let isEnabled = window.isSidebarModeEnabled(mode)

        return Button {
            guard isEnabled else { return }
            window.activateSidebarMode(mode)
        } label: {
            Group {
                if #available(macOS 26.0, *), usesSystemGlass, isSelected {
                    modeIcon(mode, isSelected: true, isEnabled: isEnabled)
                        .background(Circle().fill(Color.accentColor))
                        .glassEffect(.clear.interactive(), in: .circle)
                } else {
                    modeIcon(mode, isSelected: isSelected, isEnabled: isEnabled)
                        .background {
                            if isSelected {
                                Circle().fill(Color.accentColor)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(Text(mode.label))
        .accessibilityLabel(Text(mode.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func modeIcon(
        _ mode: WindowSidebarState.Mode,
        isSelected: Bool,
        isEnabled: Bool
    ) -> some View {
        Image(systemName: mode.symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(
                isSelected
                    ? AnyShapeStyle(TermindColor.selectedForeground)
                    : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
            )
            .frame(width: 36, height: 36)
            .contentShape(.circle)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch window.sidebarMode {
        case .navigation:
            WorkspaceNavigatorView()
        case .assistant:
            AssistantPanelView()
        case .snippets:
            SnippetsSidebarView()
        case .history:
            HistorySidebarView()
        }
    }
}

nonisolated struct SidebarListItem: Identifiable, Hashable, Sendable {
    nonisolated enum SectionID: Hashable, Sendable {
        case package(UUID)
        case ungrouped
        case results

        var snippetExpansionID: String? {
            switch self {
            case .package(let id): "package:\(id.uuidString.lowercased())"
            case .ungrouped: "ungrouped"
            case .results: nil
            }
        }
    }

    nonisolated enum ID: Hashable, Sendable {
        case section(SectionID)
        case snippet(Snippet.ID)
        case history(CommandHistoryEntry.ID)
        case sftpHistory(SFTPHistoryEntry.ID)
        case connection(ConnectionHistoryEntry.ID)
    }

    nonisolated enum Content: Hashable, Sendable {
        /// Expansion deliberately does not live in this value. ListViewKit can
        /// then keep the header row alive while the click inside it removes the
        /// section's Snippet rows.
        case section(SectionID, title: String, count: Int)
        case snippet(Snippet)
        case history(CommandHistoryEntry, isNaming: Bool)
        case sftpHistory(SFTPHistoryEntry, displayedPath: String)
        case connection(ConnectionHistoryEntry, Host, address: String)
    }

    let id: ID
    let content: Content

    static func section(_ id: SectionID, title: String, count: Int = 0) -> Self {
        .init(id: .section(id), content: .section(id, title: title, count: count))
    }

    static func snippet(_ snippet: Snippet) -> Self {
        .init(id: .snippet(snippet.id), content: .snippet(snippet))
    }

    static func history(_ entry: CommandHistoryEntry, isNaming: Bool) -> Self {
        .init(id: .history(entry.id), content: .history(entry, isNaming: isNaming))
    }

    static func sftpHistory(
        _ entry: SFTPHistoryEntry, displayedPath: String? = nil
    ) -> Self {
        .init(
            id: .sftpHistory(entry.id),
            content: .sftpHistory(entry, displayedPath: displayedPath ?? entry.path)
        )
    }

    static func connection(
        _ entry: ConnectionHistoryEntry, host: Host, address: String
    ) -> Self {
        .init(
            id: .connection(entry.id),
            content: .connection(entry, host, address: address)
        )
    }

    /// One height for every content card, because they are one card with four
    /// fillings — see `SidebarCard`. The exception is a command being named as
    /// a snippet, where the row grows for the field rather than the field being
    /// squeezed into a row built for two lines of text.
    var height: CGFloat {
        switch content {
        case .section(let section, _, _):
            section.snippetExpansionID == nil ? 32 : 34
        case .snippet: Metrics.Sidebar.historyCardHeight
        case .history(_, let isNaming):
            isNaming
                ? Metrics.Sidebar.historyCardEditingHeight
                : Metrics.Sidebar.historyCardHeight
        case .sftpHistory, .connection: Metrics.Sidebar.historyCardHeight
        }
    }
}

/// Persistent presentation state belonging only to the compact Snippets shelf.
/// The main Snippets page continues to use `SnippetPackage.isExpanded`.
nonisolated struct SnippetSidebarExpansionState: Equatable, Sendable {
    private(set) var collapsedSectionIDs: Set<String>

    init(rawValue: String = "") {
        collapsedSectionIDs = Set(rawValue.split(separator: "\n").map(String.init))
    }

    var rawValue: String {
        collapsedSectionIDs.sorted().joined(separator: "\n")
    }

    func isExpanded(_ section: SidebarListItem.SectionID) -> Bool {
        guard let id = section.snippetExpansionID else { return true }
        return !collapsedSectionIDs.contains(id)
    }

    mutating func setExpanded(
        _ expanded: Bool,
        for section: SidebarListItem.SectionID
    ) {
        guard let id = section.snippetExpansionID else { return }
        if expanded {
            collapsedSectionIDs.remove(id)
        } else {
            collapsedSectionIDs.insert(id)
        }
    }
}

nonisolated struct SnippetSidebarGroup: Sendable {
    let id: SidebarListItem.SectionID
    let title: String
    let snippets: [Snippet]
}

/// Keeps filtering and folding rules testable without constructing the AppKit list.
nonisolated enum SnippetSidebarListBuilder {
    static func groupedItems(
        _ groups: [SnippetSidebarGroup],
        expansion: SnippetSidebarExpansionState
    ) -> [SidebarListItem] {
        var items: [SidebarListItem] = []
        for group in groups where !group.snippets.isEmpty {
            items.append(.section(group.id, title: group.title, count: group.snippets.count))
            if expansion.isExpanded(group.id) {
                items.append(contentsOf: group.snippets.map(SidebarListItem.snippet))
            }
        }
        return items
    }

    static func searchItems(
        _ snippets: [Snippet], title: String
    ) -> [SidebarListItem] {
        [.section(.results, title: title, count: snippets.count)]
            + snippets.map(SidebarListItem.snippet)
    }
}

/// The heading above a group of cards.
///
/// Inset exactly like `SidebarSectionHeader` in the Navigator and the Assistant,
/// so every section label in the column starts on the same vertical line —
/// this one used to sit 2pt further right for no reason anyone could see except
/// by putting the two modes side by side.
private func sidebarSectionTitle(_ title: String) -> some View {
    Text(title)
        .termindSidebarSectionLabel()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(
            .horizontal,
            Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
        )
        .padding(.top, Metrics.Space.s)
}

/// A Snippet package heading with the same count, chevron and hit region as an
/// Assistant section. It owns the storage read so changing expansion never
/// changes the `SidebarListItem` representing this row.
private struct SnippetSidebarSectionHeaderRow: View {
    let section: SidebarListItem.SectionID
    let title: String
    let count: Int

    @AppStorage(DesktopSettingsKey.snippetsSidebarCollapsedSections)
    private var collapsedSections = ""

    private var isExpanded: Bool {
        SnippetSidebarExpansionState(rawValue: collapsedSections).isExpanded(section)
    }

    private func toggleExpansion() {
        var state = SnippetSidebarExpansionState(rawValue: collapsedSections)
        state.setExpanded(!state.isExpanded(section), for: section)
        collapsedSections = state.rawValue
    }

    var body: some View {
        SidebarSectionHeader(
            title: title, count: count, height: 34,
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded != isExpanded { toggleExpansion() }
                }
            )
        )
    }
}

private struct SidebarNativeList: NSViewRepresentable {
    typealias NSViewType = SidebarListContainer
    typealias List = ListView<SidebarListItem>
    typealias Renderer = @MainActor (SidebarListItem) -> AnyView

    let items: [SidebarListItem]
    /// Whether adding and removing rows animates.
    ///
    /// History says no. Its content reorders as a side effect of something the
    /// user did elsewhere — opening a host moves it to the top of Recents — and
    /// animating that reorder makes the list jump under a pointer that is aimed
    /// at a row which has already moved.
    var animatesStructuralChanges = true
    /// The right-click menu for the space below the last row.
    var blankAreaMenu: (() -> [NativeMenuEntry])?
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [SidebarListItem],
        animatesStructuralChanges: Bool = true,
        blankAreaMenu: (() -> [NativeMenuEntry])? = nil,
        @ViewBuilder renderer: @escaping @MainActor (SidebarListItem) -> some View
    ) {
        self.items = items
        self.animatesStructuralChanges = animatesStructuralChanges
        self.blankAreaMenu = blankAreaMenu
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        SidebarListContainer(listView: context.coordinator.makeListView())
    }

    func updateNSView(_ container: NSViewType, context: Context) {
        container.blankAreaMenu = blankAreaMenu
        context.coordinator.update(
            listView: container.listView,
            items: items,
            renderer: renderer,
            locale: locale,
            colorScheme: colorScheme,
            animated: animatesStructuralChanges
        )
    }

    @MainActor
    final class Coordinator {
        private let content = HostingListContent<SidebarListItem>()

        func makeListView() -> List {
            let listView = List()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.topInset = Metrics.Space.xs
            listView.bottomInset = Metrics.Space.xs
            listView.estimatedRowHeight = Metrics.Sidebar.navigationRowHeight
            listView.rows {
                ListRow(HostingListRow.self)
                    .height { item, _ in item.height }
                    .configure { [weak self] row, item, _ in
                        self?.configure(row, item: item)
                    }
            }
            return listView
        }

        func update(
            listView: List,
            items: [SidebarListItem],
            renderer: @escaping Renderer,
            locale: Locale,
            colorScheme: ColorScheme,
            animated: Bool
        ) {
            content.update(
                listView, items: items, renderer: renderer, locale: locale,
                colorScheme: colorScheme, animated: animated
            )
        }

        private func configure(_ row: HostingListRow, item: SidebarListItem) {
            content.configure(row, item: item)
        }
    }
}

/// Wraps the list so the space below the last row has a menu of its own.
///
/// A row's own menu is installed by SwiftUI on its hosting view, which AppKit
/// finds first; only a click that landed on no row walks up the responder chain
/// this far. That is exactly the distinction the blank-area menu needs, and it
/// needs no geometry to make it.
@MainActor
final class SidebarListContainer: NSView {
    let listView: ListView<SidebarListItem>
    var blankAreaMenu: (() -> [NativeMenuEntry])?

    init(listView: ListView<SidebarListItem>) {
        self.listView = listView
        super.init(frame: .zero)
        listView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listView)
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = blankAreaMenu?(), !entries.isEmpty else {
            return super.menu(for: event)
        }
        return NativeMenuEntry.menu(entries)
    }
}

// MARK: - Session Snippets

/// The global Snippet shelf. Execution always respects the Snippet's saved
/// Targets; the focused terminal is never an implicit destination.
private struct SnippetsSidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale

    @State private var query = ""
    @State private var destructiveSnippet: Snippet?
    @State private var selectedSnippetID: Snippet.ID?
    @AppStorage(DesktopSettingsKey.snippetsSidebarCollapsedSections)
    private var collapsedSections = ""

    var body: some View {
        VStack(spacing: 0) {
            if displayedSnippets.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SidebarNativeList(
                    items: snippetListItems,
                    // A fold removes rows during the header's click. Matching
                    // Assistant, keep that structural update synchronous.
                    animatesStructuralChanges: false,
                    blankAreaMenu: { blankAreaMenu }
                ) { item in
                    switch item.content {
                    case .section(let section, let title, let count):
                        if section.snippetExpansionID == nil {
                            sidebarSectionTitle(title)
                        } else {
                            SnippetSidebarSectionHeaderRow(
                                section: section, title: title, count: count
                            )
                        }
                    case .snippet(let snippet):
                        snippetRow(snippet)
                    case .history, .sftpHistory, .connection:
                        EmptyView()
                    }
                }
            }

            SidebarSearchFooter(
                text: $query,
                placeholder: localized("Search Snippets")
            )
        }
        .confirmationDialog(
            "Execute a destructive script?",
            isPresented: Binding(
                get: { destructiveSnippet != nil },
                set: { if !$0 { destructiveSnippet = nil } }
            ),
            titleVisibility: .visible,
            presenting: destructiveSnippet
        ) { snippet in
            Button("Execute", role: .destructive) { executeNow(snippet) }
            Button("Cancel", role: .cancel) { destructiveSnippet = nil }
        } message: { snippet in
            let assessment = CommandRiskClassifier.assess(snippet.body)
            Text(([snippet.body] + assessment.reasons).joined(separator: "\n"))
        }
    }

    private var snippetListItems: [SidebarListItem] {
        if !query.isEmpty {
            return SnippetSidebarListBuilder.searchItems(
                displayedSnippets, title: localized("Results")
            )
        }
        var groups = packageSections.map {
            SnippetSidebarGroup(
                id: .package($0.package.id), title: $0.path, snippets: $0.snippets
            )
        }
        if !ungrouped.isEmpty {
            groups.append(
                SnippetSidebarGroup(
                    id: .ungrouped, title: localized("Ungrouped"), snippets: ungrouped
                )
            )
        }
        return SnippetSidebarListBuilder.groupedItems(
            groups,
            expansion: SnippetSidebarExpansionState(rawValue: collapsedSections)
        )
    }

    /// This shelf only runs what is already saved; snippets are made on the
    /// Snippets page. With nothing under the pointer both verbs grey out rather
    /// than the menu not appearing, so the shelf answers a right-click the same
    /// way wherever it lands.
    private var blankAreaMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(title: localized("Copy"), symbol: MenuSymbol.copy, isEnabled: false),
            NativeMenuEntry(
                title: localized("Execute"), symbol: MenuSymbol.execute, isEnabled: false
            ),
        ]
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        SSHSessionSnippetRow(
            snippet: snippet, isSelected: selectedSnippetID == snippet.id
        )
        .termindSidebarRow(isSelected: selectedSnippetID == snippet.id) {
            [
                NativeMenuEntry(title: localized("Copy"), symbol: MenuSymbol.copy) {
                    copyToPasteboard(snippet.body)
                },
                NativeMenuEntry(title: localized("Execute"), symbol: MenuSymbol.execute) {
                    requestExecution(snippet)
                },
            ]
        }
        .onTapGesture(count: 2) { requestExecution(snippet) }
        .onTapGesture { selectedSnippetID = snippet.id }
    }

    private var displayedSnippets: [Snippet] {
        query.isEmpty ? app.hostLibrary.snippets : app.hostLibrary.searchSnippets(query)
    }

    private var ungrouped: [Snippet] { app.hostLibrary.snippets(in: nil) }

    private func localized(_ key: String.LocalizationValue) -> String {
        AppLocalization.string(key, locale: locale)
    }

    private var packageSections: [(package: SnippetPackage, path: String, snippets: [Snippet])] {
        flattenPackages(app.hostLibrary.rootSnippetPackages)
    }

    private func flattenPackages(
        _ packages: [SnippetPackage]
    ) -> [(package: SnippetPackage, path: String, snippets: [Snippet])] {
        packages.flatMap { package in
            let current = (
                package: package,
                path: app.hostLibrary.snippetPackagePath(package.id) ?? package.name,
                snippets: app.hostLibrary.snippets(in: package.id)
            )
            return [current] + flattenPackages(app.hostLibrary.childSnippetPackages(of: package.id))
        }
    }

    private func requestExecution(_ snippet: Snippet) {
        if snippet.targetHostIDs.isEmpty {
            window.hostChooser = .snippet(
                SnippetHostChooserRequest(
                    snippetIDs: [snippet.id], strategy: .fillMissingTargets
                ))
            return
        }
        if CommandRiskClassifier.assess(snippet.body).requiresSecondConfirmation {
            destructiveSnippet = snippet
        } else {
            executeNow(snippet)
        }
    }

    private func executeNow(_ snippet: Snippet) {
        app.execute([snippet], in: window)
        destructiveSnippet = nil
    }
}

// MARK: - Focus-sensitive History

/// One card, four fillings.
///
/// The three histories and the Snippet shelf answer the same shape of question
/// about different things — what did I run, what did I open, where did I
/// connect, what have I saved — so they are one component rather than four
/// lists that drifted into four paddings, four heights and four ideas of where
/// the selection highlight goes.
private struct SidebarCard<Trailing: View>: View {
    let symbol: String?
    var symbolTint: AnyShapeStyle?
    let title: String
    var titleIsMonospaced = false
    let subtitle: String?
    var subtitleIsMonospaced = true
    var truncatesSubtitleInMiddle = false
    let isSelected: Bool
    @ViewBuilder var trailing: Trailing

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(
                        SidebarSelectionStyle.foreground(
                            isSelected: isSelected,
                            controlActiveState: controlActiveState,
                            unselected: symbolTint ?? AnyShapeStyle(.secondary)
                        )
                    )
                    .frame(width: Metrics.Sidebar.rowIcon)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleIsMonospaced ? .caption.monospaced() : .body)
                    .lineLimit(titleIsMonospaced ? 2 : 1)
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleIsMonospaced ? .caption.monospaced() : .caption)
                        .foregroundStyle(
                            SidebarSelectionStyle.foreground(
                                isSelected: isSelected,
                                controlActiveState: controlActiveState,
                                unselected: AnyShapeStyle(.secondary)
                            )
                        )
                        .lineLimit(1)
                        .truncationMode(truncatesSubtitleInMiddle ? .middle : .tail)
                }
            }

            Spacer(minLength: Metrics.Space.s)

            trailing
        }
        .padding(.horizontal, Metrics.Space.m)
        .frame(height: Metrics.Sidebar.historyCardHeight)
        .contentShape(.rect)
    }
}

private struct HistorySidebarView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        if window.selectedWorkspace?.focusedPane.sshSession != nil {
            SSHCommandHistorySidebar()
        } else if window.selectedWorkspace?.focusedPane.sftpSession != nil {
            SFTPBrowseHistorySidebar()
        } else {
            ConnectionHistorySidebar()
        }
    }
}

private struct SSHCommandHistorySidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var destructiveEntry: CommandHistoryEntry?
    @State private var confirmsClear = false
    @State private var namingEntryID: CommandHistoryEntry.ID?
    @State private var snippetName = ""
    @State private var selectedID: CommandHistoryEntry.ID?

    private var sshSession: SSHSessionModel? {
        window.selectedWorkspace?.focusedPane.sshSession
    }

    private var isSavedHost: Bool {
        guard let hostID = sshSession?.hostID else { return false }
        return app.hostLibrary.host(hostID) != nil
    }

    private var allEntries: [CommandHistoryEntry] {
        guard let sshSession else { return [] }
        _ = app.commandHistory.revision
        if isSavedHost {
            return app.commandHistory.entries(for: sshSession.hostID, matching: query)
        }
        let entries = sshSession.transientCommandHistory
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if allEntries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .sidebarBlankAreaMenu { globalMenu }
            } else {
                SidebarNativeList(
                    items: historyListItems,
                    animatesStructuralChanges: false,
                    blankAreaMenu: { globalMenu }
                ) { item in
                    switch item.content {
                    case .section(_, let title, _):
                        sidebarSectionTitle(title)
                    case .history(let entry, _):
                        historyRow(entry)
                    case .snippet, .sftpHistory, .connection:
                        EmptyView()
                    }
                }
            }

            if sshSession?.status.isLive == true,
                sshSession?.shellIntegrationAvailable == false
            {
                // Bounded by a line limit rather than by `fixedSize`.
                //
                // `fixedSize(horizontal: false, vertical: true)` makes this
                // sentence report whatever height it needs at whatever width it
                // is asked about — and SwiftUI asks about very narrow ones while
                // sizing the column. Ninety characters at a probe width wrap
                // into a paragraph, the split view adopts that as the height it
                // must offer, and *both* columns get proposed it: measured as
                // the detail column being handed 912x1125 instead of 912x688,
                // which is what threw the connection journey upward. It only
                // ever happened in History because this is the one sidebar mode
                // with a child that demands height, and it appears exactly when
                // `status.isLive` flips — the instant a connection succeeds.
                Text("This session is not recording history. Enable Shell Integration and use bash, zsh, or fish.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.Space.m)
                    .padding(.vertical, Metrics.Space.s)
            }

            SidebarSearchFooter(text: $query, placeholder: String(localized: "Search History"))
        }
        .confirmationDialog(
            "Clear command history for this Host?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive, action: clearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all saved commands for the current Host.")
        }
        .confirmationDialog(
            "Execute a destructive command?",
            isPresented: Binding(
                get: { destructiveEntry != nil },
                set: { if !$0 { destructiveEntry = nil } }
            ),
            titleVisibility: .visible,
            presenting: destructiveEntry
        ) { entry in
            Button("Execute", role: .destructive) { executeNow(entry) }
            Button("Cancel", role: .cancel) { destructiveEntry = nil }
        } message: { entry in
            let assessment = CommandRiskClassifier.assess(entry.command)
            Text(([entry.command] + assessment.reasons).joined(separator: "\n"))
        }
    }

    /// The blank area offers the same menu a row does, with everything that
    /// needs a row greyed out. Clear History is not one of those — it is about
    /// the list, so it stays live where there is nothing under the pointer.
    private var globalMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(
                title: String(localized: "Copy"), symbol: MenuSymbol.copy, isEnabled: false
            ),
            NativeMenuEntry(
                title: String(localized: "Save as Snippet"),
                symbol: MenuSymbol.saveAsSnippet,
                isEnabled: false
            ),
            .separator,
            NativeMenuEntry(
                title: String(localized: "Clear History"),
                symbol: MenuSymbol.clearHistory,
                isEnabled: !allEntries.isEmpty,
            ) { confirmsClear = true },
        ]
    }

    @ViewBuilder
    private func historyRow(_ entry: CommandHistoryEntry) -> some View {
        if namingEntryID == entry.id {
            VStack(alignment: .leading, spacing: 3) {
                SidebarInlineTextField(
                    text: $snippetName,
                    prompt: String(localized: "Snippet Name"),
                    onSubmit: { saveSnippet(from: entry) },
                    onCancel: cancelSnippetNaming
                )
                .frame(height: 18)
                .padding(.horizontal, Metrics.Space.s)
                .padding(.vertical, 4)
                .background(
                    Color.primary.opacity(0.055),
                    in: .rect(cornerRadius: Metrics.Radius.small)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.Radius.small)
                        .strokeBorder(Color.accentColor.opacity(0.55))
                }
                Text(entry.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, Metrics.Space.m)
        } else {
            CommandHistoryCard(
                entry: entry,
                isSelected: selectedID == entry.id,
                delete: { delete(entry) }
            )
            .onTapGesture(count: 2) {
                selectedID = entry.id
                execute(entry)
            }
            .onTapGesture {
                selectedID = entry.id
                insert(entry)
            }
            .termindSidebarRow(isSelected: selectedID == entry.id) {
                [
                    NativeMenuEntry(
                        title: String(localized: "Copy"), symbol: MenuSymbol.copy
                    ) {
                        copyToPasteboard(entry.command)
                    },
                    NativeMenuEntry(
                        title: String(localized: "Save as Snippet"),
                        symbol: MenuSymbol.saveAsSnippet
                    ) {
                        beginSnippetNaming(entry)
                    },
                    .separator,
                    NativeMenuEntry(
                        title: String(localized: "Remove this History"),
                        symbol: MenuSymbol.removeHistory,
                    ) { delete(entry) },
                    NativeMenuEntry(
                        title: String(localized: "Clear History"),
                        symbol: MenuSymbol.clearHistory,
                    ) { confirmsClear = true },
                ]
            }
        }
    }

    private var historyListItems: [SidebarListItem] {
        let entries = allEntries.map {
            SidebarListItem.history($0, isNaming: namingEntryID == $0.id)
        }
        guard !query.isEmpty else { return entries }
        return [.section(.results, title: String(localized: "Results"))] + entries
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                "No History", systemImage: "clock.arrow.circlepath",
                description: Text("Commands confirmed by the remote shell appear here.")
            )
        }
    }

    private func insert(_ entry: CommandHistoryEntry) {
        guard let workspace = window.selectedWorkspace, let sshSession = workspace.focusedPane.sshSession else {
            return
        }
        workspace.deliver(entry.command, from: sshSession)
    }

    private func execute(_ entry: CommandHistoryEntry) {
        if CommandRiskClassifier.assess(entry.command).requiresSecondConfirmation {
            destructiveEntry = entry
        } else {
            executeNow(entry)
        }
    }

    private func executeNow(_ entry: CommandHistoryEntry) {
        guard let workspace = window.selectedWorkspace, let sshSession = workspace.focusedPane.sshSession else {
            return
        }
        workspace.deliver(entry.command, from: sshSession, submit: true)
        destructiveEntry = nil
    }

    private func delete(_ entry: CommandHistoryEntry) {
        if isSavedHost {
            app.commandHistory.delete(entry.id)
        } else {
            sshSession?.deleteTransientHistory(entry.id)
        }
    }

    private func clearHistory() {
        guard let sshSession else { return }
        if isSavedHost {
            app.commandHistory.clear(for: sshSession.hostID)
        } else {
            sshSession.clearTransientHistory()
        }
    }

    private func beginSnippetNaming(_ entry: CommandHistoryEntry) {
        snippetName = ""
        namingEntryID = entry.id
    }

    private func cancelSnippetNaming() {
        namingEntryID = nil
        snippetName = ""
    }

    private func saveSnippet(from entry: CommandHistoryEntry) {
        let name = snippetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        app.hostLibrary.upsert(Snippet(title: name, body: entry.command))
        cancelSnippetNaming()
    }
}

private struct SFTPBrowseHistorySidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var selectedID: SFTPHistoryEntry.ID?
    @State private var confirmsClear = false

    private var session: SFTPSessionModel? {
        window.selectedWorkspace?.focusedPane.sftpSession
    }

    private var entries: [SFTPHistoryEntry] {
        guard let session else { return [] }
        _ = app.sftpHistory.revision
        let values = app.sftpHistory.entries(for: session.hostID)
        guard !query.isEmpty else { return values }
        return values.filter {
            $0.path.localizedCaseInsensitiveContains(query)
                || session.displayPath($0.path).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "No History", systemImage: "clock.arrow.circlepath",
                            description: Text("Folders you visit and files you open appear here.")
                        )
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sidebarBlankAreaMenu { globalMenu }
            } else {
                SidebarNativeList(
                    items: entries.map {
                        SidebarListItem.sftpHistory(
                            $0, displayedPath: session?.displayPath($0.path)
                        )
                    },
                    animatesStructuralChanges: false,
                    blankAreaMenu: { globalMenu }
                ) { item in
                    if case .sftpHistory(let entry, let displayedPath) = item.content {
                        row(entry, displayedPath: displayedPath)
                    }
                }
            }

            SidebarSearchFooter(text: $query, placeholder: String(localized: "Search History"))
        }
        .confirmationDialog(
            "Clear File History for this Host?", isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                if let session { app.sftpHistory.clear(for: session.hostID) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var globalMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(
                title: String(localized: "Open"), symbol: MenuSymbol.open, isEnabled: false
            ),
            NativeMenuEntry(
                title: String(localized: "Remove this History"),
                symbol: MenuSymbol.removeHistory,
                isEnabled: false
            ),
            .separator,
            NativeMenuEntry(
                title: String(localized: "Clear History"),
                symbol: MenuSymbol.clearHistory,
                isEnabled: !entries.isEmpty,
            ) { confirmsClear = true },
        ]
    }

    private func row(_ entry: SFTPHistoryEntry, displayedPath: String) -> some View {
        SidebarCard(
            symbol: entry.kind.symbol,
            symbolTint: entry.kind == .directory
                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary),
            title: entry.name,
            subtitle: displayedPath,
            truncatesSubtitleInMiddle: true,
            isSelected: selectedID == entry.id
        ) {
            EmptyView()
        }
        .onTapGesture(count: 2) { reopen(entry) }
        .onTapGesture { selectedID = entry.id }
        .termindSidebarRow(isSelected: selectedID == entry.id) {
            [
                NativeMenuEntry(title: String(localized: "Open"), symbol: MenuSymbol.open) {
                    reopen(entry)
                },
                .separator,
                NativeMenuEntry(
                    title: String(localized: "Remove this History"),
                    symbol: MenuSymbol.removeHistory,
                ) { app.sftpHistory.delete(entry.id) },
                NativeMenuEntry(
                    title: String(localized: "Clear History"),
                    symbol: MenuSymbol.clearHistory,
                ) { confirmsClear = true },
            ]
        }
    }

    private func reopen(_ entry: SFTPHistoryEntry) {
        guard let session else { return }
        switch entry.kind {
        case .directory:
            session.navigate(to: entry.path)
        case .file:
            session.reopenHistoryFile(at: entry.path, coordinator: app.sftpTransfers) {
                if NSWorkspace.shared.open($0) {
                    session.recordOpenedFile(at: entry.path)
                }
            }
        }
    }
}

private struct ConnectionHistorySidebar: View {
    @Environment(\.locale) private var locale
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var query = ""
    @State private var selectedID: ConnectionHistoryEntry.ID?
    @State private var confirmsClear = false

    private var allRows: [(entry: ConnectionHistoryEntry, host: Host)] {
        _ = app.connectionHistory.revision
        return app.connectionHistory.entries().compactMap { entry in
            app.hostLibrary.host(entry.hostID).map { (entry, $0) }
        }
    }

    private var rows: [(entry: ConnectionHistoryEntry, host: Host)] {
        guard !query.isEmpty else { return allRows }
        return allRows.filter { entry, host in
            host.matches(query)
                || app.hostLibrary.loginAddress(for: host)
                    .localizedCaseInsensitiveContains(query)
                || entry.kind.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "No History", systemImage: "clock.arrow.circlepath",
                            description: Text("Hosts you connect to appear here.")
                        )
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sidebarBlankAreaMenu { globalMenu }
            } else {
                // Never animated. Reopening a record inserts a new one at the
                // top, and animating that insertion moves the clicked row.
                SidebarNativeList(
                    items: rows.map { entry, host in
                        .connection(
                            entry, host: host,
                            address: app.hostLibrary.loginAddress(for: host)
                        )
                    },
                    animatesStructuralChanges: false,
                    blankAreaMenu: { globalMenu }
                ) { item in
                    if case .connection(let entry, let host, let address) = item.content {
                        row(entry, host: host, address: address)
                    }
                }
            }

            SidebarSearchFooter(text: $query, placeholder: String(localized: "Search History"))
        }
        .confirmationDialog(
            "Clear connection history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                app.clearConnectionHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all connection history without deleting any Hosts.")
        }
    }

    private var globalMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(
                title: String(localized: "Quick Connect"),
                symbol: MenuSymbol.quickConnect,
                isEnabled: false
            ),
            NativeMenuEntry(
                title: String(localized: "Remove this History"),
                symbol: MenuSymbol.removeHistory,
                isEnabled: false
            ),
            .separator,
            NativeMenuEntry(
                title: String(localized: "Clear History"),
                symbol: MenuSymbol.clearHistory,
                isEnabled: !allRows.isEmpty,
            ) { confirmsClear = true },
        ]
    }

    private func row(
        _ entry: ConnectionHistoryEntry, host: Host, address: String
    ) -> some View {
        SidebarCard(
            symbol: entry.kind.symbol,
            title: host.name,
            subtitle: address,
            isSelected: selectedID == entry.id
        ) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.kind.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(entry.connectedAt, format: .relative(presentation: .numeric).locale(locale))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .onTapGesture(count: 2) {
            app.open(
                host,
                as: entry.kind == .ssh ? .sshSession : .sftpSession,
                in: window
            )
        }
        .onTapGesture { selectedID = entry.id }
        .termindSidebarRow(isSelected: selectedID == entry.id) {
            HostMenuEntries.entries(for: host, app: app, window: window) + [
                .separator,
                NativeMenuEntry(
                    title: String(localized: "Remove this History"),
                    symbol: MenuSymbol.removeHistory,
                ) { app.connectionHistory.delete(entry.id) },
                NativeMenuEntry(
                    title: String(localized: "Clear History"),
                    symbol: MenuSymbol.clearHistory,
                ) { confirmsClear = true },
            ]
        }
    }
}

/// The blank-area menu for an empty-state view, which has no list to hang one on.
private struct SidebarBlankAreaMenu: ViewModifier {
    let entries: () -> [NativeMenuEntry]

    func body(content: Content) -> some View {
        content.overlay {
            NativeBlankAreaMenu(entries: { _ in entries() })
        }
    }
}

extension View {
    fileprivate func sidebarBlankAreaMenu(
        _ entries: @escaping () -> [NativeMenuEntry]
    ) -> some View {
        modifier(SidebarBlankAreaMenu(entries: entries))
    }
}

/// A command as it appears in History: what was run, and how alarming it is.
private struct CommandHistoryCard: View {
    let entry: CommandHistoryEntry
    let isSelected: Bool
    let delete: () -> Void

    @Environment(\.locale) private var locale
    @State private var isHovering = false

    var body: some View {
        SidebarCard(
            symbol: nil,
            title: entry.command,
            titleIsMonospaced: true,
            subtitle: subtitle,
            subtitleIsMonospaced: false,
            isSelected: isSelected
        ) {
            ZStack {
                if isHovering {
                    Button(action: delete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this History")
                    .accessibilityLabel("Remove this History")
                } else {
                    RiskBadge(
                        assessment: CommandRiskClassifier.assess(entry.command),
                        compact: true
                    )
                }
            }
            .frame(width: 18, height: 18, alignment: .center)
        }
        .onHover { isHovering = $0 }
        .help(Text(entry.command))
    }

    private var subtitle: String {
        var parts = [
            entry.executedAt.formatted(
                .relative(presentation: .numeric).locale(locale)
            )
        ]
        if let duration = entry.duration,
            let formatted = formattedDuration(duration)
        {
            parts.append(formatted)
        }
        return parts.joined(separator: " · ")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits =
            duration < 60 ? [.second] : [.hour, .minute, .second]
        return formatter.string(from: max(0, duration))
    }
}

/// A native borderless field whose editor remains transparent inside a Sidebar
/// list. SwiftUI's focused `TextField` paints an opaque control background here,
/// which looks like a white strip in light mode and ignores the row material.
private struct SidebarInlineTextField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.stringValue = text
        field.placeholderString = prompt
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.requestFocus(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private let onSubmit: () -> Void
        private let onCancel: () -> Void
        private var didRequestFocus = false

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func requestFocus(for field: NSTextField) {
            guard !didRequestFocus else { return }
            didRequestFocus = true
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            onCancel()
            return true
        }

        @objc func submit() {
            onSubmit()
        }
    }
}

/// A snippet on the shelf, built from the same card as the three histories —
/// name over script, one height, one set of insets. The shelf and History are
/// the same kind of list and used to be two slightly different ones.
private struct SSHSessionSnippetRow: View {
    let snippet: Snippet
    let isSelected: Bool

    private var assessment: RiskAssessment { CommandRiskClassifier.assess(snippet.body) }

    var body: some View {
        SidebarCard(
            symbol: nil,
            title: snippet.title,
            subtitle: snippet.body,
            isSelected: isSelected
        ) {
            RiskBadge(assessment: assessment, compact: true)
        }
        .help(Text(snippet.body))
    }
}
