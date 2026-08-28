import AppKit
import ListViewKit
import SwiftUI

/// The window's one left-hand column. A glass mode rail switches the Navigator
/// and three Workspace tools in place without the square selection segments of
/// `NSSegmentedControl`.
struct SidebarView: View {
    let detailCatalog: ContextPanelDetailCatalog

    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let availableDetails = detailCatalog.availableIDs

        VStack(spacing: 0) {
            modeSelector
                .padding(.horizontal, Metrics.Space.m)
                .padding(.vertical, Metrics.Space.s)
            sidebarContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: availableDetails, initial: true) {
            window.sidebar.pruneSelections(available: availableDetails)
        }
        .onChange(of: focusedPaneID, initial: true) {
            window.sidebar.focusedPaneDidChange(to: window.selectedWorkspace?.focusedPane)
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
            guard mode == .navigation || isEnabled else { return }
            window.sidebarMode = mode
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
                    ? AnyShapeStyle(Color.white)
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
            SSHSessionSnippetsSidebar()
        case .history:
            AdaptiveHistorySidebar()
        }
    }
}

nonisolated struct ContextSidebarListItem: Identifiable, Hashable, Sendable {
    nonisolated enum SectionID: Hashable, Sendable {
        case package(UUID)
        case ungrouped
        case results
    }

    nonisolated enum ID: Hashable, Sendable {
        case section(SectionID)
        case snippet(Snippet.ID)
        case history(CommandHistoryEntry.ID)
        case sftpHistory(SFTPHistoryEntry.ID)
        case connection(Host.ID)
    }

    nonisolated enum Content: Hashable, Sendable {
        case section(SectionID, title: String)
        case snippet(Snippet)
        case history(CommandHistoryEntry, isNaming: Bool)
        case sftpHistory(SFTPHistoryEntry)
        case connection(Host, address: String)
    }

    let id: ID
    let content: Content

    static func section(_ id: SectionID, title: String) -> Self {
        .init(id: .section(id), content: .section(id, title: title))
    }

    static func snippet(_ snippet: Snippet) -> Self {
        .init(id: .snippet(snippet.id), content: .snippet(snippet))
    }

    static func history(_ entry: CommandHistoryEntry, isNaming: Bool) -> Self {
        .init(id: .history(entry.id), content: .history(entry, isNaming: isNaming))
    }

    static func sftpHistory(_ entry: SFTPHistoryEntry) -> Self {
        .init(id: .sftpHistory(entry.id), content: .sftpHistory(entry))
    }

    static func connection(_ host: Host, address: String) -> Self {
        .init(id: .connection(host.id), content: .connection(host, address: address))
    }

    /// One height for every content card, because they are one card with four
    /// fillings — see `SidebarCard`. The exception is a command being named as
    /// a snippet, where the row grows for the field rather than the field being
    /// squeezed into a row built for two lines of text.
    var height: CGFloat {
        switch content {
        case .section: 32
        case .snippet: Metrics.Sidebar.historyCardHeight
        case .history(_, let isNaming):
            isNaming
                ? Metrics.Sidebar.historyCardEditingHeight
                : Metrics.Sidebar.historyCardHeight
        case .sftpHistory, .connection: Metrics.Sidebar.historyCardHeight
        }
    }
}

/// The heading above a group of cards.
///
/// Inset exactly like `SidebarSectionHeader` in the Navigator and the Assistant,
/// so every section label in the column starts on the same vertical line —
/// this one used to sit 2pt further right for no reason anyone could see except
/// by putting the two modes side by side.
private func contextSidebarSectionTitle(_ title: String) -> some View {
    Text(title)
        .termindSidebarSectionLabel()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(
            .horizontal,
            Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
        )
        .padding(.top, Metrics.Space.s)
}

private struct ContextSidebarNativeList: NSViewRepresentable {
    typealias NSViewType = ContextSidebarListContainer
    typealias List = ListView<ContextSidebarListItem>
    typealias Renderer = @MainActor (ContextSidebarListItem) -> AnyView

    let items: [ContextSidebarListItem]
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
        items: [ContextSidebarListItem],
        animatesStructuralChanges: Bool = true,
        blankAreaMenu: (() -> [NativeMenuEntry])? = nil,
        @ViewBuilder renderer: @escaping @MainActor (ContextSidebarListItem) -> some View
    ) {
        self.items = items
        self.animatesStructuralChanges = animatesStructuralChanges
        self.blankAreaMenu = blankAreaMenu
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        ContextSidebarListContainer(listView: context.coordinator.makeListView())
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
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [ContextSidebarListItem] = []

        func makeListView() -> List {
            let listView = List()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.topInset = Metrics.Space.xs
            listView.bottomInset = Metrics.Space.xs
            listView.estimatedRowHeight = Metrics.Sidebar.navigationRowHeight
            listView.rows {
                ListRow(ContextSidebarHostingRow.self)
                    .height { item, _ in item.height }
                    .configure { [weak self] row, item, _ in
                        self?.configure(row, item: item)
                    }
            }
            return listView
        }

        func update(
            listView: List,
            items: [ContextSidebarListItem],
            renderer: @escaping Renderer,
            locale: Locale,
            colorScheme: ColorScheme,
            animated: Bool
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items, animated: animated && !content.isEmpty)
            }
            content = items
        }

        private func configure(_ row: ContextSidebarHostingRow, item: ContextSidebarListItem) {
            guard let renderer else { return }
            let root = renderer(item)
                .id(item.id)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(root))
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
final class ContextSidebarListContainer: NSView {
    let listView: ListView<ContextSidebarListItem>
    var blankAreaMenu: (() -> [NativeMenuEntry])?

    init(listView: ListView<ContextSidebarListItem>) {
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

@MainActor
private final class ContextSidebarHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView.rootView = AnyView(EmptyView())
    }

    func configure(rootView: AnyView) {
        hostingView.rootView = rootView
    }
}

// MARK: - Session Snippets

/// The global Snippet shelf. Execution always respects the Snippet's saved
/// Targets; the focused terminal is never an implicit destination.
private struct SSHSessionSnippetsSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var destructiveSnippet: Snippet?
    @State private var selectedSnippetID: Snippet.ID?

    var body: some View {
        VStack(spacing: 0) {
            if displayedSnippets.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContextSidebarNativeList(
                    items: snippetListItems,
                    blankAreaMenu: { blankAreaMenu }
                ) { item in
                    switch item.content {
                    case .section(_, let title):
                        contextSidebarSectionTitle(title)
                    case .snippet(let snippet):
                        snippetRow(snippet)
                    case .history, .sftpHistory, .connection:
                        EmptyView()
                    }
                }
            }

            SidebarSearchFooter(text: $query, placeholder: String(localized: "Search Snippets"))
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

    private var snippetListItems: [ContextSidebarListItem] {
        if !query.isEmpty {
            return [.section(.results, title: "Results")]
                + displayedSnippets.map(ContextSidebarListItem.snippet)
        }
        var items: [ContextSidebarListItem] = []
        for section in packageSections where !section.snippets.isEmpty {
            items.append(.section(.package(section.package.id), title: section.path))
            items.append(contentsOf: section.snippets.map(ContextSidebarListItem.snippet))
        }
        if !ungrouped.isEmpty {
            items.append(.section(.ungrouped, title: "Ungrouped"))
            items.append(contentsOf: ungrouped.map(ContextSidebarListItem.snippet))
        }
        return items
    }

    /// This shelf only runs what is already saved; snippets are made on the
    /// Snippets page. With nothing under the pointer both verbs grey out rather
    /// than the menu not appearing, so the shelf answers a right-click the same
    /// way wherever it lands.
    private var blankAreaMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(title: String(localized: "Copy"), isEnabled: false),
            NativeMenuEntry(title: String(localized: "Execute"), isEnabled: false),
        ]
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        SSHSessionSnippetRow(
            snippet: snippet, isSelected: selectedSnippetID == snippet.id
        )
            .termindSidebarRow(isSelected: selectedSnippetID == snippet.id) {
                [
                    NativeMenuEntry(title: String(localized: "Copy")) {
                        copyToPasteboard(snippet.body)
                    },
                    NativeMenuEntry(title: String(localized: "Execute")) {
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
            window.hostChooser = .snippet(SnippetHostChooserRequest(
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
                    .foregroundStyle(SidebarSelectionStyle.foreground(
                        isSelected: isSelected,
                        controlActiveState: controlActiveState,
                        unselected: symbolTint ?? AnyShapeStyle(.secondary)
                    ))
                    .frame(width: Metrics.Sidebar.rowIcon)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleIsMonospaced ? .caption.monospaced() : .body)
                    .lineLimit(titleIsMonospaced ? 2 : 1)
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleIsMonospaced ? .caption.monospaced() : .caption)
                        .foregroundStyle(SidebarSelectionStyle.foreground(
                            isSelected: isSelected,
                            controlActiveState: controlActiveState,
                            unselected: AnyShapeStyle(.secondary)
                        ))
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

private struct AdaptiveHistorySidebar: View {
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
                ContextSidebarNativeList(
                    items: historyListItems,
                    animatesStructuralChanges: false,
                    blankAreaMenu: { globalMenu }
                ) { item in
                    switch item.content {
                    case .section(_, let title):
                        contextSidebarSectionTitle(title)
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
                Text("This session is not recording history. Enable Shell Integration and use bash, zsh, or fish.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            NativeMenuEntry(title: String(localized: "Copy"), isEnabled: false),
            NativeMenuEntry(title: String(localized: "Save as Snippet"), isEnabled: false),
            .separator,
            NativeMenuEntry(
                title: String(localized: "Clear History"),
                isEnabled: !allEntries.isEmpty,
                isDestructive: true
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
                    NativeMenuEntry(title: String(localized: "Copy")) {
                        copyToPasteboard(entry.command)
                    },
                    NativeMenuEntry(title: String(localized: "Save as Snippet")) {
                        beginSnippetNaming(entry)
                    },
                    .separator,
                    NativeMenuEntry(
                        title: String(localized: "Delete from History"),
                        isDestructive: true
                    ) { delete(entry) },
                    NativeMenuEntry(
                        title: String(localized: "Clear History"), isDestructive: true
                    ) { confirmsClear = true },
                ]
            }
        }
    }

    private var historyListItems: [ContextSidebarListItem] {
        let entries = allEntries.map {
            ContextSidebarListItem.history($0, isNaming: namingEntryID == $0.id)
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
        guard let tab = window.selectedWorkspace, let sshSession = tab.focusedPane.sshSession else { return }
        tab.deliver(entry.command, from: sshSession)
    }

    private func execute(_ entry: CommandHistoryEntry) {
        if CommandRiskClassifier.assess(entry.command).requiresSecondConfirmation {
            destructiveEntry = entry
        } else {
            executeNow(entry)
        }
    }

    private func executeNow(_ entry: CommandHistoryEntry) {
        guard let tab = window.selectedWorkspace, let sshSession = tab.focusedPane.sshSession else { return }
        tab.deliver(entry.command, from: sshSession, submit: true)
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
        return app.sftpHistory.entries(for: session.hostID, matching: query)
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
                ContextSidebarNativeList(
                    items: entries.map(ContextSidebarListItem.sftpHistory),
                    animatesStructuralChanges: false,
                    blankAreaMenu: { globalMenu }
                ) { item in
                    if case .sftpHistory(let entry) = item.content {
                        row(entry)
                    }
                }
            }

            SidebarSearchFooter(text: $query, placeholder: String(localized: "Search History"))
        }
        .confirmationDialog(
            "Clear SFTP history for this Host?", isPresented: $confirmsClear,
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
            NativeMenuEntry(title: String(localized: "Open"), isEnabled: false),
            NativeMenuEntry(
                title: String(localized: "Delete from History"), isEnabled: false
            ),
            .separator,
            NativeMenuEntry(
                title: String(localized: "Clear History"),
                isEnabled: !entries.isEmpty,
                isDestructive: true
            ) { confirmsClear = true },
        ]
    }

    private func row(_ entry: SFTPHistoryEntry) -> some View {
        SidebarCard(
            symbol: entry.kind.symbol,
            symbolTint: entry.kind == .directory
                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary),
            title: entry.name,
            subtitle: entry.path,
            truncatesSubtitleInMiddle: true,
            isSelected: selectedID == entry.id
        ) {
            EmptyView()
        }
        .onTapGesture(count: 2) { reopen(entry) }
        .onTapGesture { selectedID = entry.id }
        .termindSidebarRow(isSelected: selectedID == entry.id) {
            [
                NativeMenuEntry(title: String(localized: "Open")) { reopen(entry) },
                .separator,
                NativeMenuEntry(
                    title: String(localized: "Delete from History"), isDestructive: true
                ) { app.sftpHistory.delete(entry.id) },
                NativeMenuEntry(
                    title: String(localized: "Clear History"), isDestructive: true
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
    @AppStorage(SettingsKey.showRecents) private var showRecents = true
    @State private var query = ""
    @State private var selectedID: Host.ID?
    @State private var confirmsClear = false

    private var allHosts: [Host] { showRecents ? app.hostLibrary.recents(limit: 10) : [] }

    private var hosts: [Host] {
        guard !query.isEmpty else { return allHosts }
        return allHosts.filter {
            $0.matches(query)
                || app.hostLibrary.loginAddress(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hosts.isEmpty {
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
                // Never animated. Opening a host moves it to the top of
                // Recents, and animating that reorder made the list jump
                // upwards under a pointer aimed at the row that had just moved.
                ContextSidebarNativeList(
                    items: hosts.map {
                        .connection($0, address: app.hostLibrary.loginAddress(for: $0))
                    },
                    animatesStructuralChanges: false,
                    blankAreaMenu: { globalMenu }
                ) { item in
                    if case .connection(let host, let address) = item.content {
                        row(host, address: address)
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
                app.hostLibrary.clearRecents()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all Hosts from Recents without deleting the Hosts themselves.")
        }
    }

    private var globalMenu: [NativeMenuEntry] {
        [
            NativeMenuEntry(title: String(localized: "Quick Connect"), isEnabled: false),
            NativeMenuEntry(
                title: String(localized: "Delete from History"), isEnabled: false
            ),
            .separator,
            NativeMenuEntry(
                title: String(localized: "Clear History"),
                isEnabled: !allHosts.isEmpty,
                isDestructive: true
            ) { confirmsClear = true },
        ]
    }

    private func row(_ host: Host, address: String) -> some View {
        SidebarCard(
            symbol: "server.rack",
            title: host.name,
            subtitle: address,
            isSelected: selectedID == host.id
        ) {
            if let date = host.lastUsedAt {
                Text(date, format: .relative(presentation: .numeric).locale(locale))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .onTapGesture(count: 2) {
            app.open(host, as: .sshSession, in: window)
        }
        .onTapGesture { selectedID = host.id }
        .termindSidebarRow(isSelected: selectedID == host.id) {
            HostMenuEntries.entries(for: host, app: app, window: window) + [
                .separator,
                NativeMenuEntry(
                    title: String(localized: "Delete from History"), isDestructive: true
                ) { app.hostLibrary.forgetRecent(host.id) },
                NativeMenuEntry(
                    title: String(localized: "Clear History"), isDestructive: true
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
            subtitle: entry.executedAt.formatted(
                .relative(presentation: .numeric).locale(locale)
            ),
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
                    .help("Delete from History")
                    .accessibilityLabel("Delete from History")
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

// MARK: - Details

/// The Sidebar's Details mode describes every selected object without inventing
/// a primary item. Disclosure groups keep a large selection scannable while
/// still allowing several records to be read side by side.
struct DetailSidebarView: View {
    let details: [ContextPanelDetailID]
    let catalog: ContextPanelDetailCatalog
    let page: VaultPage?

    @State private var expanded: Set<ContextPanelDetailID> = []

    var body: some View {
        Group {
            if details.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.Space.l) {
                        Text(selectionSummary)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        ForEach(details) { detail in
                            if let presentation = catalog.presentation(for: detail) {
                                DisclosureGroup(isExpanded: expansionBinding(for: detail)) {
                                    presentation.content
                                        .padding(.top, Metrics.Space.l)
                                        .padding(.leading, Metrics.Space.xl)
                                } label: {
                                    presentation.label
                                }
                                .padding(Metrics.Space.l)
                                .background(
                                    .quaternary.opacity(0.28),
                                    in: .rect(cornerRadius: Metrics.Radius.large)
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.Space.xl)
                }
            }
        }
        .labeledContentStyle(.automatic)
        .onChange(of: details, initial: true) { _, current in
            expanded.formIntersection(current)
            if expanded.isEmpty, let first = current.first { expanded.insert(first) }
            if current.count == 1, let only = current.first { expanded.insert(only) }
        }
    }

    private var selectionSummary: String {
        details.count == 1
            ? String(localized: "1 item selected")
            : String(localized: "\(details.count) items selected")
    }

    private func expansionBinding(for detail: ContextPanelDetailID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(detail) },
            set: { isExpanded in
                if isExpanded { expanded.insert(detail) } else { expanded.remove(detail) }
            }
        )
    }

    private var emptyState: some View {
        let content = catalog.emptyState(for: page)
        return ContentUnavailableView {
            Label(content.title, systemImage: content.symbol)
        } description: {
            Text(content.description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HostDetailContent: View {
    @Environment(\.locale) private var locale
    let host: Host

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            HStack(spacing: Metrics.Space.s) {
                Button("Quick Connect") { app.open(host, as: .sshSession, in: window) }
                    .buttonStyle(.borderedProminent)
                HostConnectMenu(hosts: [host])
                Button("Edit") { window.openHostEditor(host: host) }
            }
            .controlSize(.small)

            LabeledContent("Status", value: app.hostLibrary.status(of: host.id).label)
            LabeledContent("Port") { Text(host.port, format: .number.grouping(.never)) }
            LabeledContent("Identity") {
                if let identity = app.hostLibrary.identity(for: host) {
                    Text("\(identity.name) · \(identity.username)")
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            if host.jumpHostID != nil || host.proxy != nil {
                LabeledContent("Route") {
                    Text(app.hostLibrary.routeSummary(for: host))
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Last Used") {
                Text(
                    host.lastUsedAt.map { $0.formatted(.relative(presentation: .named).locale(locale)) }
                        ?? String(localized: "Never"))
            }

            if !host.tags.isEmpty {
                DetailSection(title: "Tags") {
                    FlowLayout(spacing: Metrics.Space.xs) {
                        ForEach(host.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, Metrics.Space.s)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.5), in: .capsule)
                        }
                    }
                }
            }

            hostKey

            let portForwardings = app.hostLibrary.portForwardings(for: host.id)
            if !portForwardings.isEmpty {
                DetailSection(title: "Port Forwarding") {
                    ForEach(portForwardings, id: \.id) { portForwarding in
                        HStack(spacing: Metrics.Space.s) {
                            Image(systemName: portForwarding.kind.symbol)
                                .foregroundStyle(
                                    app.forwarding.isEnabled(portForwarding.id) ? .green : .secondary
                                )
                            Text(portForwarding.summary)
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var hostKey: some View {
        let entries = app.hostLibrary.knownHosts(for: host)
        DetailSection(title: "Host Key") {
            if !entries.isEmpty {
                if entries.contains(where: \.isMismatched) {
                    Label(
                        "This server recently presented a key that is not in the trusted set.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: Metrics.Space.s) {
                        Text(entry.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Metrics.Space.s) {
                            CardChip(text: entry.algorithm.displayName, symbol: "lock.shield")
                            Text(entry.addedAt, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: Metrics.Space.s) {
                            Button("Copy Fingerprint") { copyToPasteboard(entry.fingerprint) }
                        }
                        .controlSize(.small)
                    }
                    if entry.id != entries.last?.id { Divider() }
                }
            } else {
                Text(
                    "No key saved yet. Termind saves it on first connection and warns if it changes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct KeyDetailContent: View {
    let key: SSHKeyRef
    let edit: () -> Void
    let export: () -> Void

    @Environment(AppModel.self) private var app

    private var identities: [Identity] { app.hostLibrary.identities(using: key.id) }

    private var algorithm: String {
        if key.algorithm == .rsa, let bits = key.keySize { return "RSA \(bits)" }
        if let bits = key.keySize { return "\(key.algorithm.displayName) · \(bits) bit" }
        return key.algorithm.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            Menu("Actions") {
                KeyObjectActions(key: key, edit: edit, export: export)
            }
            .menuStyle(.button)
            .controlSize(.small)

            LabeledContent("Algorithm", value: algorithm)
            LabeledContent("Stored in", value: key.storage.displayName)
            LabeledContent("Created") { Text(key.createdAt, format: .dateTime) }
            LabeledContent("Passphrase") {
                Text(
                    !key.hasPassphrase
                        ? String(localized: "None")
                        : String(localized: "Required at use")
                )
            }
            LabeledContent("Authentication") {
                Text(key.requiresUserPresence ? String(localized: "Required") : String(localized: "Not required"))
            }

            DetailTextBlock(title: "Fingerprint", text: key.fingerprint)
            DetailTextBlock(
                title: "Public Key",
                text: key.publicKey.isEmpty ? String(localized: "Not available") : key.publicKey
            )
            if !key.certificate.isEmpty {
                DetailTextBlock(title: "Certificate", text: key.certificate)
                if let certificate = try? SSHUserCertificate.parse(
                    key.certificate, matching: key.publicKey
                ), let warning = certificate.validityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            DetailSection(title: "Used by Identities") {
                if identities.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(identities) { identity in
                        Label("\(identity.name) · \(identity.username)", systemImage: "person.badge.key.fill")
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IdentityDetailContent: View {
    @Environment(\.locale) private var locale
    let identity: Identity
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    private var key: SSHKeyRef? { identity.keyID.flatMap { app.hostLibrary.key($0) } }
    private var hosts: [Host] { app.hostLibrary.hosts(using: identity.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            Button("Edit", action: edit)
                .controlSize(.small)

            LabeledContent("Username", value: identity.username)
            LabeledContent("Password") {
                Text(passwordStatus)
                    .foregroundStyle(passwordStatusIsWarning ? .orange : .primary)
            }
            LabeledContent("Key") {
                if let key {
                    Text(key.label)
                } else if identity.usesKey {
                    Text("Missing").foregroundStyle(.orange)
                } else {
                    Text("Not configured").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Last Used") {
                Text(
                    identity.lastUsedAt.map { $0.formatted(.relative(presentation: .named).locale(locale)) }
                        ?? String(localized: "Never"))
            }

            if !identity.notes.isEmpty { DetailTextBlock(title: "Notes", text: identity.notes, monospaced: false) }

            DetailSection(title: "Used by Hosts") {
                if hosts.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(hosts) { host in
                        Label(host.name, systemImage: "server.rack")
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var passwordStatus: String {
        switch app.hostLibrary.passwordAvailability(for: identity) {
        case .notConfigured: String(localized: "Not configured")
        case .available: String(localized: "Configured")
        case .missing: String(localized: "Not available on this Mac")
        case .failed: String(localized: "Keychain unavailable")
        }
    }

    private var passwordStatusIsWarning: Bool {
        switch app.hostLibrary.passwordAvailability(for: identity) {
        case .missing, .failed: true
        case .notConfigured, .available: false
        }
    }
}

struct SnippetDetailContent: View {
    let snippet: Snippet

    @Environment(AppModel.self) private var app

    private var assessment: RiskAssessment { CommandRiskClassifier.assess(snippet.body) }
    private var targets: [Host] { snippet.targetHostIDs.compactMap { app.hostLibrary.host($0) } }
    private var packagePath: String {
        app.hostLibrary.snippetPackagePath(snippet.packageID) ?? String(localized: "Ungrouped")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            LabeledContent("Package", value: packagePath)
            LabeledContent("Risk") { RiskBadge(assessment: assessment) }

            DetailTextBlock(title: "Scripts", text: snippet.body)

            if !assessment.reasons.isEmpty {
                DetailSection(title: "Risk Assessment") {
                    ForEach(assessment.reasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.caption)
                            .foregroundStyle(assessment.risk.tint)
                    }
                }
            }

            DetailSection(title: "Targets") {
                if targets.isEmpty {
                    Text("Choose hosts when you execute this snippet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(targets) { host in
                        VStack(alignment: .leading, spacing: 1) {
                            Label(host.name, systemImage: "server.rack")
                            Text(app.hostLibrary.loginAddress(for: host))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }
                        .font(.caption)
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailTextBlock: View {
    let title: LocalizedStringKey
    let text: String
    var monospaced = true

    var body: some View {
        DetailSection(title: title) {
            Text(text)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
