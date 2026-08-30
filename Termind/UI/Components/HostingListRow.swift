import AppKit
import ListViewKit
import SwiftUI

@MainActor
final class HostingListRow: ListRowView {
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

/// Shared renderer and diff state for SwiftUI-backed ListView coordinators.
/// List-specific setup, selection and scrolling stay in their owning adapter.
@MainActor
final class HostingListContent<Item> where
    Item: Identifiable & Hashable & SendableMetatype, Item.ID: Hashable
{
    typealias Renderer = @MainActor (Item) -> AnyView

    private var renderer: Renderer?
    private var locale = Locale.current
    private var colorScheme = ColorScheme.light
    private var items: [Item] = []

    // Swift 6.3.3's optimizer can crash while synthesizing generic deinit.
    @_optimize(none) deinit {}

    @discardableResult
    func update(
        _ listView: ListView<Item>, items newItems: [Item], renderer: @escaping Renderer,
        locale newLocale: Locale, colorScheme newColorScheme: ColorScheme,
        animated: Bool
    ) -> Bool {
        self.renderer = renderer
        let environmentChanged = locale != newLocale || colorScheme != newColorScheme
        let identitiesChanged = items.map(\.id) != newItems.map(\.id)
        locale = newLocale
        colorScheme = newColorScheme
        if !identitiesChanged {
            for (old, new) in zip(items, newItems) where old != new { listView.update(new) }
            if environmentChanged { listView.reloadData() }
        } else {
            listView.apply(newItems, animated: animated && !items.isEmpty)
        }
        items = newItems
        return identitiesChanged
    }

    func configure(_ row: HostingListRow, item: Item) {
        guard let root = rootView(for: item) else { return }
        row.configure(rootView: root)
    }

    func rootView(for item: Item) -> AnyView? {
        guard let renderer else { return nil }
        return AnyView(renderer(item)
            .id(item.id)
            .environment(\.locale, locale)
            .environment(\.colorScheme, colorScheme))
    }
}

protocol CursorHostingListItem: Identifiable, Hashable {
    var isCursor: Bool { get }
}

/// Fixed-height hosting list shared by keyboard-driven chooser sheets.
struct CursorHostingList<Item>: NSViewRepresentable where
    Item: CursorHostingListItem & SendableMetatype, Item.ID: Hashable
{
    typealias NSViewType = ListView<Item>
    typealias Renderer = @MainActor (Item) -> AnyView

    let items: [Item]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [Item],
        @ViewBuilder renderer: @escaping @MainActor (Item) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private let content = HostingListContent<Item>()

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 52
            listView.rows {
                ListRow(HostingListRow.self)
                    .height { _, _ in 52 }
                    .configure { [weak self] row, item, _ in
                        self?.content.configure(row, item: item)
                    }
            }
            return listView
        }

        func update(
            _ listView: NSViewType, items: [Item], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
        ) {
            content.update(
                listView, items: items, renderer: renderer, locale: locale,
                colorScheme: colorScheme, animated: true
            )
            if let cursor = items.first(where: \.isCursor) {
                listView.scrollToRow(with: cursor.id, at: .nearest, animated: false)
            }
        }
    }
}
