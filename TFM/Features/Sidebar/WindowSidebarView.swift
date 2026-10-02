import AppKit
import ListViewKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

/// The window's one left-hand column. Its mode buttons share one glass capsule
/// with a neutral selection highlight, keeping the symbols above the material.
struct WindowSidebarView: View {

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var focusedMode: WindowSidebarState.Mode?
    @Namespace private var modeSelectionNamespace

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

    private var modeSelector: some View {
        HStack(spacing: Metrics.Space.xs) {
            ForEach(WindowSidebarState.Mode.allCases) { mode in
                modeButton(mode)
            }
        }
        .padding(Metrics.Space.xs)
        .termindGlassCapsule()
        .overlay {
            HStack(spacing: Metrics.Space.xs) {
                ForEach(WindowSidebarState.Mode.allCases) { mode in
                    Color.clear.frame(width: 36, height: 36)
                        .overlay(alignment: .topTrailing) {
                            NotificationCountBadge(unreadCount(for: mode)).offset(y: 3)
                        }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Metrics.Space.xs)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : Motion.panel, value: window.sidebarMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Navigation.sidebar))
    }

    private func modeButton(_ mode: WindowSidebarState.Mode) -> some View {
        let isSelected = window.sidebarMode == mode
        let isEnabled = window.isSidebarModeEnabled(mode)

        return Button {
            guard isEnabled else { return }
            window.activateSidebarMode(mode)
        } label: {
            modeIcon(mode, isSelected: isSelected, isEnabled: isEnabled)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                            .matchedGeometryEffect(id: "selection", in: modeSelectionNamespace)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .focused($focusedMode, equals: mode)
        .focusEffectDisabled()
        .overlay {
            if focusedMode == mode && controlActiveState == .key {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .disabled(!isEnabled)
        .help(Text(mode.label))
        .accessibilityLabel(Text(mode.label))
        .accessibilityValue(
            unreadCount(for: mode) > 0
                ? String(localized: AppStrings.Notifications.unread(unreadCount(for: mode))) : ""
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func modeIcon(
        _ mode: WindowSidebarState.Mode,
        isSelected: Bool,
        isEnabled: Bool
    ) -> some View {
        Image(systemName: mode.symbol)
            .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 36, height: 36)
    }

    private func unreadCount(for mode: WindowSidebarState.Mode) -> Int {
        switch mode {
        case .navigation: window.unreadCompletionCount
        case .assistant: app.unreadAssistantNotificationCount
        case .snippets, .history: 0
        }
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
        container.locale = locale
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
    var locale = Locale.current
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
        return NativeMenuEntry.menu(entries, locale: locale)
    }
}

@MainActor
enum TerminalSidebarMenuBuilder {
    static func snippets(
        snippet: Snippet?, canInsert: Bool, locale: Locale,
        copy: @escaping (Snippet) -> Void,
        insert: @escaping (Snippet) -> Void
    ) -> [NativeMenuEntry] {
        [
            NativeMenuEntry(
                title: localized(AppStrings.Common.copy, locale: locale),
                symbol: MenuSymbol.copy,
                isEnabled: snippet != nil
            ) {
                if let snippet { copy(snippet) }
            },
            NativeMenuEntry(
                title: localized(AppStrings.Common.insert, locale: locale),
                symbol: MenuSymbol.insert,
                isEnabled: snippet != nil && canInsert
            ) {
                if let snippet { insert(snippet) }
            },
        ]
    }

    static func history(
        entry: CommandHistoryEntry?, canInsert: Bool, locale: Locale,
        copy: @escaping (CommandHistoryEntry) -> Void,
        insert: @escaping (CommandHistoryEntry) -> Void,
        saveAsSnippet: @escaping (CommandHistoryEntry) -> Void
    ) -> [NativeMenuEntry] {
        let entries = [
            NativeMenuEntry(
                title: localized(AppStrings.Common.copy, locale: locale),
                symbol: MenuSymbol.copy,
                isEnabled: entry != nil
            ) {
                if let entry { copy(entry) }
            },
            NativeMenuEntry(
                title: localized(AppStrings.Common.insert, locale: locale),
                symbol: MenuSymbol.insert,
                isEnabled: entry != nil && canInsert
            ) {
                if let entry { insert(entry) }
            },
            NativeMenuEntry(
                title: localized(AppStrings.Snippets.saveAsSnippet, locale: locale),
                symbol: MenuSymbol.saveAsSnippet,
                isEnabled: entry != nil
            ) {
                if let entry { saveAsSnippet(entry) }
            },
        ]
        return entries
    }

    private static func localized(
        _ key: LocalizedStringResource, locale: Locale
    ) -> String {
        AppLocalization.resolve(key, locale: locale)
    }
}

// MARK: - Session Snippets

/// The global Snippet shelf inserts into the focused terminal. The full
/// Snippets page remains the place for executing a Snippet on its saved Targets.
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
                placeholder: localized(AppStrings.Snippets.searchSnippets)
            )
        }
        .confirmationDialog(
            AppStrings.Snippets.runADestructiveScriptConfirmation,
            isPresented: Binding(
                get: { destructiveSnippet != nil },
                set: { if !$0 { destructiveSnippet = nil } }
            ),
            titleVisibility: .visible,
            presenting: destructiveSnippet
        ) { snippet in
            Button(AppStrings.Common.run.swiftUIKey, role: .destructive) { executeNow(snippet) }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { destructiveSnippet = nil }
        } message: { snippet in
            let assessment = CommandRiskClassifier.assess(snippet.body)
            Text(([snippet.body] + assessment.reasons).joined(separator: "\n"))
        }
    }

    private var snippetListItems: [SidebarListItem] {
        if !query.isEmpty {
            return SnippetSidebarListBuilder.searchItems(
                displayedSnippets, title: localized(AppStrings.Common.results)
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
                    id: .ungrouped, title: localized(AppStrings.Common.ungrouped), snippets: ungrouped
                )
            )
        }
        return SnippetSidebarListBuilder.groupedItems(
            groups,
            expansion: SnippetSidebarExpansionState(rawValue: collapsedSections)
        )
    }

    /// With nothing under the pointer both verbs grey out rather than the menu
    /// not appearing, so the shelf answers a right-click the same way wherever
    /// it lands.
    private var blankAreaMenu: [NativeMenuEntry] {
        TerminalSidebarMenuBuilder.snippets(
            snippet: nil, canInsert: canInsert, locale: locale,
            copy: copy, insert: insert
        )
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        SSHSessionSnippetRow(
            snippet: snippet, isSelected: selectedSnippetID == snippet.id
        )
        .termindSidebarRow(isSelected: selectedSnippetID == snippet.id) {
            TerminalSidebarMenuBuilder.snippets(
                snippet: snippet, canInsert: canInsert, locale: locale,
                copy: copy, insert: insert
            )
        }
        .onTapGesture(count: 2) { execute(snippet) }
        .onTapGesture {
            selectedSnippetID = snippet.id
            insert(snippet)
        }
    }

    private var displayedSnippets: [Snippet] {
        query.isEmpty ? app.hostLibrary.snippets : app.hostLibrary.searchSnippets(query)
    }

    private var ungrouped: [Snippet] { app.hostLibrary.snippets(in: nil) }

    private func localized(_ key: LocalizedStringResource) -> String {
        AppLocalization.resolve(key, locale: locale)
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

    private var canInsert: Bool {
        window.selectedWorkspace?.focusedPane.sshSession?.status.isLive == true
            || window.selectedWorkspace?.focusedPane.telnetSession?.status.isLive == true
    }

    private func copy(_ snippet: Snippet) {
        copyToPasteboard(snippet.body)
    }

    private func insert(_ snippet: Snippet) {
        guard let workspace = window.selectedWorkspace, canInsert else { return }
        workspace.deliverToFocusedTerminal(snippet.body)
    }

    private func execute(_ snippet: Snippet) {
        guard canInsert else { return }
        if CommandRiskClassifier.assess(snippet.body).requiresSecondConfirmation {
            destructiveSnippet = snippet
        } else {
            executeNow(snippet)
        }
    }

    private func executeNow(_ snippet: Snippet) {
        guard let workspace = window.selectedWorkspace, canInsert else {
            destructiveSnippet = nil
            return
        }
        workspace.deliverToFocusedTerminal(snippet.body, submit: true)
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
    let title: String
    var titleIsMonospaced = false
    var titleLineLimit: Int?
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
                        SidebarSelectionStyle.iconForeground(
                            isSelected: isSelected,
                            controlActiveState: controlActiveState
                        )
                    )
                    .frame(width: Metrics.Sidebar.rowIcon)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleIsMonospaced ? .caption.monospaced() : .body)
                    .lineLimit(titleLineLimit ?? (titleIsMonospaced ? 2 : 1))
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

enum DesktopHistoryPresentation {
    static let limit = 100

    static func limited<Entry>(_ entries: [Entry]) -> [Entry] {
        Array(entries.prefix(limit))
    }
}

private struct HistorySidebarView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        if window.selectedWorkspace?.focusedPane.sshSession != nil {
            SSHCommandHistorySidebar()
        } else if window.selectedWorkspace?.focusedPane.sftpChannel != nil {
            SFTPBrowseHistorySidebar()
        } else {
            ConnectionHistorySidebar()
        }
    }
}

private struct SSHCommandHistorySidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale

    @State private var query = ""
    @State private var destructiveEntry: CommandHistoryEntry?
    @State private var namingEntryID: CommandHistoryEntry.ID?
    @State private var snippetName = ""
    @State private var selectedID: CommandHistoryEntry.ID?

    private var sshSession: SSHSessionModel? {
        window.selectedWorkspace?.focusedPane.sshSession
    }

    private var allEntries: [CommandHistoryEntry] {
        guard let sshSession else { return [] }
        _ = sshSession.commandHistory.revision
        return DesktopHistoryPresentation.limited(sshSession.commandHistory.entries(matching: query))
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
                Text(AppStrings.Terminal.commandHistoryRequirement)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.Space.m)
                    .padding(.vertical, Metrics.Space.s)
            }

            SidebarSearchFooter(text: $query, placeholder: String(localized: AppStrings.Common.searchHistory))
        }
        .confirmationDialog(
            AppStrings.Assistant.executeADestructiveCommandConfirmation,
            isPresented: Binding(
                get: { destructiveEntry != nil },
                set: { if !$0 { destructiveEntry = nil } }
            ),
            titleVisibility: .visible,
            presenting: destructiveEntry
        ) { entry in
            Button(AppStrings.Common.execute.swiftUIKey, role: .destructive) { executeNow(entry) }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { destructiveEntry = nil }
        } message: { entry in
            let assessment = CommandRiskClassifier.assess(entry.command)
            Text(([entry.command] + assessment.reasons).joined(separator: "\n"))
        }
    }

    /// The blank area offers the row menu with entry-specific actions disabled.
    private var globalMenu: [NativeMenuEntry] {
        historyMenu(for: nil)
    }

    @ViewBuilder
    private func historyRow(_ entry: CommandHistoryEntry) -> some View {
        if namingEntryID == entry.id {
            VStack(alignment: .leading, spacing: 3) {
                SidebarInlineTextField(
                    text: $snippetName,
                    prompt: String(localized: AppStrings.Snippets.snippetName),
                    onSubmit: { saveSnippet(from: entry) },
                    onCancel: cancelSnippetNaming
                ).singleLinePaste()
                    .frame(height: 18)
                    .padding(.horizontal, Metrics.Space.s)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.Radius.small)
                            .strokeBorder(Color.accentColor.opacity(0.55))
                    }
                Text(CommandHistoryPresentation.title(for: entry))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, Metrics.Space.m)
            .termindSidebarRowBackground(isSelected: false)
        } else {
            CommandHistoryCard(
                entry: entry,
                isSelected: selectedID == entry.id
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
                historyMenu(for: entry)
            }
        }
    }

    private func historyMenu(for entry: CommandHistoryEntry?) -> [NativeMenuEntry] {
        TerminalSidebarMenuBuilder.history(
            entry: entry,
            canInsert: canInsert,
            locale: locale,
            copy: { copyToPasteboard($0.command) },
            insert: insert,
            saveAsSnippet: beginSnippetNaming
        )
    }

    private var historyListItems: [SidebarListItem] {
        let entries = allEntries.map {
            SidebarListItem.history($0, isNaming: namingEntryID == $0.id)
        }
        guard !query.isEmpty else { return entries }
        return [.section(.results, title: String(localized: AppStrings.Common.results))] + entries
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                AppStrings.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath",
                description: Text(AppStrings.Terminal.commandsConfirmedByTheRemoteShellAppearHere)
            )
        }
    }

    private func insert(_ entry: CommandHistoryEntry) {
        guard let workspace = window.selectedWorkspace,
            let sshSession = workspace.focusedPane.sshSession,
            sshSession.status.isLive
        else { return }
        workspace.deliver(entry.command, from: sshSession)
    }

    private func execute(_ entry: CommandHistoryEntry) {
        guard canInsert else { return }
        if CommandRiskClassifier.assess(entry.command).requiresSecondConfirmation {
            destructiveEntry = entry
        } else {
            executeNow(entry)
        }
    }

    private func executeNow(_ entry: CommandHistoryEntry) {
        guard let workspace = window.selectedWorkspace,
            let sshSession = workspace.focusedPane.sshSession,
            sshSession.status.isLive
        else {
            destructiveEntry = nil
            return
        }
        workspace.deliver(entry.command, from: sshSession, submit: true)
        destructiveEntry = nil
    }

    private func beginSnippetNaming(_ entry: CommandHistoryEntry) {
        snippetName = ""
        namingEntryID = entry.id
    }

    private var canInsert: Bool {
        sshSession?.status.isLive == true
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

    private var session: SFTPChannelModel? {
        window.selectedWorkspace?.focusedPane.sftpChannel
    }

    private var entries: [SFTPHistoryEntry] {
        guard let session else { return [] }
        _ = session.history.revision
        let values = session.history.entries()
        let matches =
            query.isEmpty
            ? values
            : values.filter {
                $0.path.localizedCaseInsensitiveContains(query)
                    || session.displayPath($0.path).localizedCaseInsensitiveContains(query)
            }
        return DesktopHistoryPresentation.limited(matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView(
                            AppStrings.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath",
                            description: Text(AppStrings.SFTP.foldersYouVisitAndFilesYouOpenAppearHere)
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

            SidebarSearchFooter(text: $query, placeholder: String(localized: AppStrings.Common.searchHistory))
        }
    }

    private var globalMenu: [NativeMenuEntry] { [] }

    private func row(_ entry: SFTPHistoryEntry, displayedPath: String) -> some View {
        SidebarCard(
            symbol: entry.kind.symbol,
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
                NativeMenuEntry(title: AppStrings.Common.open, symbol: MenuSymbol.open) {
                    reopen(entry)
                }
            ]
        }
    }

    private func reopen(_ entry: SFTPHistoryEntry) {
        guard let session else { return }
        switch entry.kind {
        case .directory:
            session.navigate(to: entry.path)
        case .file:
            session.reopenHistoryFile(at: entry.path, coordinator: app.sftpTransfers, edits: app.sftpEdits) {
                [history = session.history] in
                if NSWorkspace.shared.open($0) {
                    history.record(kind: .file, path: entry.path)
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
        let matches =
            query.isEmpty
            ? allRows
            : allRows.filter { entry, host in
                host.matches(query)
                    || historyAddress(entry, host: host)
                        .localizedCaseInsensitiveContains(query)
                    || entry.kind.label.localizedCaseInsensitiveContains(query)
                    || app.devices.name(for: entry.sourceDeviceID)?
                        .localizedCaseInsensitiveContains(query) == true
            }
        return DesktopHistoryPresentation.limited(matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView(
                            AppStrings.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath",
                            description: Text(AppStrings.Connections.hostsYouConnectToAppearHere)
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
                            address: historyAddress(entry, host: host)
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

            SidebarSearchFooter(text: $query, placeholder: String(localized: AppStrings.Common.searchHistory))
        }
        .confirmationDialog(
            AppStrings.Connections.clearConnectionHistoryConfirmation,
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.clearHistory.swiftUIKey, role: .destructive) {
                app.clearConnectionHistory()
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Workspace.clearHistoryWarning)
        }
    }

    private func historyAddress(_ entry: ConnectionHistoryEntry, host: Host) -> String {
        app.hostLibrary.loginAddress(
            for: host, protocol: entry.kind == .telnet ? .telnet : .ssh)
    }

    private var globalMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(
                title: AppStrings.Vault.quickConnect,
                symbol: MenuSymbol.quickConnect,
                isEnabled: false
            ),
            NativeMenuEntry(
                title: AppStrings.Common.delete,
                symbol: MenuSymbol.delete,
                imageVisibility: .visible,
                isEnabled: false
            ),
            .separator,
            NativeMenuEntry(
                title: AppStrings.Common.clearAll,
                symbol: MenuSymbol.clearHistory,
                imageVisibility: .visible,
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
                Text(app.devices.name(for: entry.sourceDeviceID) ?? "—")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.connectedAt, format: .relative(presentation: .numeric).locale(locale))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
        .onTapGesture {
            selectedID = entry.id
            reopen(entry, host: host)
        }
        .termindSidebarRow(isSelected: selectedID == entry.id) {
            HostMenuEntries.entries(
                for: host, app: app, window: window, includesCopySSHCommand: false
            ) + [
                NativeMenuEntry(
                    title: AppStrings.Common.delete,
                    symbol: MenuSymbol.delete,
                    imageVisibility: .visible,
                ) { app.connectionHistory.delete(entry.id) },
                .separator,
                NativeMenuEntry(
                    title: AppStrings.Common.clearAll,
                    symbol: MenuSymbol.clearHistory,
                    imageVisibility: .visible,
                ) { confirmsClear = true },
            ]
        }
    }

    private func reopen(_ entry: ConnectionHistoryEntry, host: Host) {
        let target: HostOpenTarget =
            switch entry.kind {
            case .ssh: .sshSession
            case .telnet: .telnetSession
            case .sftp: .sftpChannel
            }
        app.open(host, as: target, in: window)
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
    @Environment(\.locale) private var locale

    var body: some View {
        let subtitle = CommandHistoryPresentation.subtitle(for: entry, locale: locale)
        SidebarCard(
            symbol: nil,
            title: CommandHistoryPresentation.title(for: entry),
            titleIsMonospaced: true,
            titleLineLimit: 1,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            subtitleIsMonospaced: false,
            isSelected: isSelected
        ) {
            RiskBadge(assessment: CommandRiskClassifier.assess(entry.command), compact: true)
                .frame(width: 18, height: 18, alignment: .center)
        }
        .help(Text(entry.command))
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
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(field)
        context.coordinator.requestFocus(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        configure(field)
    }

    private func configure(_ field: NSTextField) {
        let font = NSFont.preferredFont(forTextStyle: .body)
        field.font = font
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: prompt,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        field.currentEditor()?.textColor = .labelColor
        field.currentEditor()?.drawsBackground = false
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
                field.currentEditor()?.textColor = .labelColor
                field.currentEditor()?.drawsBackground = false
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                let value = SingleLineFieldEditing.normalizedValue(in: field)
            else { return }
            text.wrappedValue = value
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
