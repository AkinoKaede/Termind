import AppKit
import ListViewKit
import SwiftUI

struct QuickOpenView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selectedID: AppCommandDescriptor.ID?
    @FocusState private var searchFocused: Bool

    private var matches: [AppCommandDescriptor] {
        app.commands.commands(app: app, window: window).filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.m) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open a page, workspace, host, or command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit(performSelection)
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
            }
            .padding(Metrics.Space.l)

            Divider()

            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuickOpenNativeList(items: quickOpenItems) { item in
                    let command = item.command
                    Button {
                        perform(command)
                    } label: {
                        HStack(spacing: Metrics.Space.m) {
                            Image(systemName: command.symbol)
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.title).lineLimit(1)
                                if let subtitle = command.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                        .background(
                            item.isSelected
                                ? Color.accentColor.opacity(0.16) : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 620, height: 430)
        .onAppear {
            searchFocused = true
            selectedID = matches.first?.id
        }
        .onChange(of: query) {
            selectedID = matches.first?.id
        }
    }

    private var quickOpenItems: [QuickOpenListItem] {
        matches.map { QuickOpenListItem(command: $0, isSelected: selectedID == $0.id) }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        let current = selectedID.flatMap { id in matches.firstIndex { $0.id == id } }
            ?? (offset > 0 ? -1 : matches.count)
        selectedID = matches[min(max(current + offset, 0), matches.count - 1)].id
        return .handled
    }

    private func performSelection() {
        let command =
            selectedID.flatMap { id in matches.first { $0.id == id } }
            ?? matches.first
        if let command { perform(command) }
    }

    private func perform(_ command: AppCommandDescriptor) {
        app.commands.perform(
            command.target, app: app, window: window,
            openSettings: { openSettings() }
        )
        dismiss()
    }
}

nonisolated struct QuickOpenListItem: Identifiable, Hashable, Sendable {
    let command: AppCommandDescriptor
    let isSelected: Bool
    var id: AppCommandDescriptor.ID { command.id }
}

private struct QuickOpenNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<QuickOpenListItem>
    typealias Renderer = @MainActor (QuickOpenListItem) -> AnyView

    let items: [QuickOpenListItem]
    let renderer: Renderer
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
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [QuickOpenListItem] = []

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 54
            listView.rows {
                ListRow(QuickOpenHostingRow.self)
                    .height { _, _ in 54 }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [QuickOpenListItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
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
                listView.apply(items)
            }
            content = items
            if let selected = items.first(where: \.isSelected) {
                listView.scrollToRow(with: selected.id, at: .nearest, animated: false)
            }
        }

        private func configure(_ row: QuickOpenHostingRow, item: QuickOpenListItem) {
            guard let renderer else { return }
            let root = renderer(item)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(root))
        }
    }
}

@MainActor
private final class QuickOpenHostingRow: ListRowView {
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
    func configure(rootView: AnyView) { hostingView.rootView = rootView }
}
