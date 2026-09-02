import AppKit
import ListViewKit
import SwiftUI

/// The window-level presentation for Command-P.
///
/// The dimming layer owns dismissal while the glass surface intercepts clicks
/// inside its bounds. Keeping this out of `RootView` leaves the window shell in
/// charge of *when* the palette is visible and this view in charge of how it
/// behaves while it is visible.
struct QuickOpenOverlay: View {
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TermindColor.shadow.opacity(colorScheme == .dark ? 0.18 : 0.10)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: close)

            QuickOpenView(dismiss: close)
                .clipShape(.rect(cornerRadius: Metrics.QuickOpen.cornerRadius))
                .termindGlassSurface(cornerRadius: Metrics.QuickOpen.cornerRadius)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.QuickOpen.cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: TermindColor.shadow.opacity(colorScheme == .dark ? 0.34 : 0.20),
                    radius: 28,
                    y: 12
                )
                .contentShape(.rect)
        }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Quick Open"))
    }

    private func close() {
        if reduceMotion {
            dismiss()
        } else {
            withAnimation(Motion.panel) { dismiss() }
        }
    }
}

struct QuickOpenView: View {
    let dismiss: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var selectedID: AppCommandDescriptor.ID?
    @FocusState private var searchFocused: Bool

    private var results: QuickOpenResults {
        QuickOpenResults(
            commands: app.commands.commands(app: app, window: window),
            query: query
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader

            Divider().opacity(0.72)

            resultContent

            Divider().opacity(0.72)

            shortcutFooter
        }
        .frame(width: Metrics.QuickOpen.width, height: Metrics.QuickOpen.height)
        .onAppear {
            searchFocused = true
            selectedID = results.commands.first?.id
        }
        .onChange(of: query) {
            selectedID = results.commands.first?.id
        }
    }

    private var searchHeader: some View {
        HStack(spacing: Metrics.Space.l) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Open a page, chat, workspace, host, or command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .focused($searchFocused)
                .onSubmit(performSelection)
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onExitCommand(perform: dismiss)
                .accessibilityLabel(Text("Search Quick Open"))

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(Text("Clear search"))
                .accessibilityLabel(Text("Clear search"))
            }

            QuickOpenKeycap(keys: "esc")
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Metrics.Space.xl)
        .frame(height: Metrics.QuickOpen.searchHeight)
    }

    @ViewBuilder
    private var resultContent: some View {
        if results.commands.isEmpty {
            VStack(spacing: Metrics.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("No results")
                    .font(.headline)
                Text("No results match “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            QuickOpenNativeList(items: listItems) { item in
                switch item {
                case .section(let section):
                    quickOpenSection(section)
                case .command(let command, let isSelected):
                    quickOpenCommand(command, isSelected: isSelected)
                }
            }
        }
    }

    private var listItems: [QuickOpenListItem] {
        results.listItems(selectedID: selectedID)
    }

    private func quickOpenSection(_ section: AppCommandSection) -> some View {
        Text(section.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, Metrics.Space.xl + Metrics.Space.xs)
            .padding(.bottom, Metrics.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func quickOpenCommand(
        _ command: AppCommandDescriptor,
        isSelected: Bool
    ) -> some View {
        Button {
            perform(command)
        } label: {
            HStack(spacing: Metrics.Space.l) {
                Image(systemName: command.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
                    .frame(width: Metrics.QuickOpen.iconSize, height: Metrics.QuickOpen.iconSize)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                            : AnyShapeStyle(Color.primary.opacity(0.055)),
                        in: .rect(cornerRadius: Metrics.Radius.medium)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text(command.title)
                        .font(.callout.weight(isSelected ? .medium : .regular))
                        .lineLimit(1)
                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                Highlight.fill(isSelected: isSelected),
                in: .rect(cornerRadius: Metrics.Space.m)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.Space.s)
        .onHover { hovering in
            if hovering { selectedID = command.id }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(commandAccessibilityLabel(command))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shortcutFooter: some View {
        HStack(spacing: Metrics.Space.xl) {
            QuickOpenShortcutHint(keys: "↑↓", label: String(localized: "Navigate"))
            QuickOpenShortcutHint(keys: "↩", label: String(localized: "Open"))
            QuickOpenShortcutHint(keys: "esc", label: String(localized: "Close"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.Space.xl)
        .frame(height: Metrics.QuickOpen.footerHeight)
        .accessibilityHidden(true)
    }

    private func commandAccessibilityLabel(_ command: AppCommandDescriptor) -> Text {
        if let subtitle = command.subtitle {
            Text("\(command.title), \(subtitle)")
        } else {
            Text(command.title)
        }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let next = results.selection(movingFrom: selectedID, by: offset) else {
            return .ignored
        }
        selectedID = next
        return .handled
    }

    private func performSelection() {
        let command =
            selectedID.flatMap { id in results.commands.first { $0.id == id } }
            ?? results.commands.first
        if let command { perform(command) }
    }

    private func perform(_ command: AppCommandDescriptor) {
        app.commands.perform(command.target, app: app, window: window)
        dismiss()
    }
}

private struct QuickOpenShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            QuickOpenKeycap(keys: keys)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuickOpenKeycap: View {
    let keys: String

    var body: some View {
        Text(verbatim: keys)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.Space.s)
            .frame(minWidth: 22, minHeight: 18)
            .background(
                Color.primary.opacity(0.055),
                in: .rect(cornerRadius: Metrics.Radius.small)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.small)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

nonisolated struct QuickOpenResults: Equatable, Sendable {
    let commands: [AppCommandDescriptor]

    init(commands: [AppCommandDescriptor], query: String) {
        let matches = commands.filter { $0.matches(query) }
        self.commands = AppCommandSection.allCases.flatMap { section in
            matches.filter { $0.section == section }
        }
    }

    var sections: [AppCommandSection] {
        AppCommandSection.allCases.filter { section in
            commands.contains { $0.section == section }
        }
    }

    func listItems(selectedID: AppCommandDescriptor.ID?) -> [QuickOpenListItem] {
        sections.flatMap { section in
            [.section(section)]
                + commands.compactMap { command in
                    guard command.section == section else { return nil }
                    return .command(command, isSelected: command.id == selectedID)
                }
        }
    }

    func selection(
        movingFrom selectedID: AppCommandDescriptor.ID?,
        by offset: Int
    ) -> AppCommandDescriptor.ID? {
        guard !commands.isEmpty else { return nil }
        let current =
            selectedID.flatMap { id in commands.firstIndex { $0.id == id } }
            ?? (offset > 0 ? -1 : commands.count)
        let next = min(max(current + offset, 0), commands.count - 1)
        return commands[next].id
    }
}

nonisolated enum QuickOpenListItem: Identifiable, Hashable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        case section(AppCommandSection)
        case command(AppCommandDescriptor.ID)
    }

    case section(AppCommandSection)
    case command(AppCommandDescriptor, isSelected: Bool)

    var id: ID {
        switch self {
        case .section(let section): .section(section)
        case .command(let command, _): .command(command.id)
        }
    }

    var height: CGFloat {
        switch self {
        case .section: Metrics.QuickOpen.sectionHeight
        case .command: Metrics.QuickOpen.rowHeight
        }
    }

    var isSelected: Bool {
        guard case .command(_, let isSelected) = self else { return false }
        return isSelected
    }
}

private struct QuickOpenNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<QuickOpenListItem>
    typealias Renderer = @MainActor (QuickOpenListItem) -> AnyView

    let items: [QuickOpenListItem]
    let renderer: Renderer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [QuickOpenListItem],
        @ViewBuilder renderer: @escaping @MainActor (QuickOpenListItem) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }

    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme, animated: !reduceMotion
        )
    }

    @MainActor
    final class Coordinator {
        private let content = HostingListContent<QuickOpenListItem>()

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.topInset = Metrics.Space.xs
            listView.bottomInset = Metrics.Space.xs
            listView.estimatedRowHeight = Metrics.QuickOpen.rowHeight
            listView.rows {
                ListRow(HostingListRow.self)
                    .height { item, _ in item.height }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [QuickOpenListItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme, animated: Bool
        ) {
            content.update(
                listView, items: items, renderer: renderer, locale: locale,
                colorScheme: colorScheme, animated: animated
            )
            if let selected = items.first(where: \.isSelected) {
                listView.scrollToRow(with: selected.id, at: .nearest, animated: false)
            }
        }

        private func configure(_ row: HostingListRow, item: QuickOpenListItem) {
            content.configure(row, item: item)
        }
    }
}
