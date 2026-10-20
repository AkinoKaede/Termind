// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
final class HostingListContent<Item>
where
    Item: Identifiable & Hashable & SendableMetatype, Item.ID: Hashable
{
    typealias Renderer = @MainActor (Item) -> AnyView

    private var renderer: Renderer?
    private var locale = Locale.current
    private var colorScheme = ColorScheme.light
    private var items: [Item] = []

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
        return AnyView(
            renderer(item)
                .id(item.id)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme))
    }
}
