// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import ListViewKit
import SwiftUI
import UIKit

private struct MobileListRowIsDisplayedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct MobileListReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MobileListSceneIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var mobileListReduceMotion: Bool {
        get { self[MobileListReduceMotionKey.self] }
        set { self[MobileListReduceMotionKey.self] = newValue }
    }
    var mobileListSceneIsActive: Bool {
        get { self[MobileListSceneIsActiveKey.self] }
        set { self[MobileListSceneIsActiveKey.self] = newValue }
    }

    var mobileListRowIsDisplayed: Bool {
        get { self[MobileListRowIsDisplayedKey.self] }
        set { self[MobileListRowIsDisplayedKey.self] = newValue }
    }
}

enum MobileNativeListSurface: Hashable {
    case grouped
    case plain

    var listBackground: UIColor {
        switch self {
        case .grouped: .systemGroupedBackground
        case .plain: .systemBackground
        }
    }

    var rowBackground: UIColor {
        switch self {
        case .grouped: .secondarySystemGroupedBackground
        case .plain: .systemBackground
        }
    }
}

struct MobileNativeList<Item, RowContent>: UIViewRepresentable
where Item: Identifiable & Hashable & SendableMetatype, RowContent: View {
    typealias UIViewType = ListView<Item>

    let items: [Item]
    let estimatedRowHeight: CGFloat
    let refreshID: AnyHashable
    let onSelect: ((Item) -> Void)?
    let onRefresh: (() async -> Void)?
    let followsBottom: Bool
    let bottomContentInset: CGFloat
    let surface: MobileNativeListSurface
    let rowRevision: ((Item) -> UInt64)?
    /// Refreshes mounted content without invalidating geometry; use rowRevision for layout changes.
    let interactionRevision: ((Item) -> UInt64)?
    let prepareUpdate: (([Item], [Item], Set<Item.ID>) -> Void)?
    let onViewportChange: ((Set<Item.ID>) -> Void)?
    let onTap: (() -> Void)?
    @ViewBuilder let rowContent: (Item) -> RowContent

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mobileListReduceMotion) private var reduceMotionOverride
    @Environment(\.scenePhase) private var scenePhase

    init(
        items: [Item], estimatedRowHeight: CGFloat = 72, refreshID: AnyHashable = 0,
        onSelect: ((Item) -> Void)? = nil,
        onRefresh: (() async -> Void)? = nil,
        followsBottom: Bool = false,
        bottomContentInset: CGFloat = 0,
        surface: MobileNativeListSurface = .grouped,
        rowRevision: ((Item) -> UInt64)? = nil,
        interactionRevision: ((Item) -> UInt64)? = nil,
        prepareUpdate: (([Item], [Item], Set<Item.ID>) -> Void)? = nil,
        onViewportChange: ((Set<Item.ID>) -> Void)? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.estimatedRowHeight = estimatedRowHeight
        self.refreshID = refreshID
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        self.followsBottom = followsBottom
        self.bottomContentInset = bottomContentInset
        self.surface = surface
        self.rowRevision = rowRevision
        self.interactionRevision = interactionRevision
        self.prepareUpdate = prepareUpdate
        self.onViewportChange = onViewportChange
        self.onTap = onTap
        self.rowContent = rowContent
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ListView<Item> {
        let listView = ListView<Item>()
        let coordinator = context.coordinator
        listView.backgroundColor = surface.listBackground
        listView.estimatedRowHeight = estimatedRowHeight
        listView.keyboardDismissMode = .interactive
        listView.rows {
            ListRow(MobileHostingListRow.self)
                .estimatedHeight(estimatedRowHeight)
                .configure { row, item, rowContext in
                    if rowContext.purpose == .display {
                        coordinator.configure(row, item: item, surface: surface)
                    } else {
                        coordinator.configurePrototype(row, item: item, surface: surface)
                    }
                }
        }
        coordinator.installTapRecognizer(on: listView)
        coordinator.observeViewport(of: listView)
        return listView
    }

    func updateUIView(_ listView: ListView<Item>, context: Context) {
        if listView.contentInset.bottom != bottomContentInset {
            listView.contentInset.bottom = bottomContentInset
        }
        context.coordinator.update(
            listView: listView,
            items: items,
            renderer: { item in AnyView(rowContent(item)) },
            onSelect: onSelect,
            onRefresh: onRefresh,
            followsBottom: followsBottom,
            surface: surface,
            refreshID: refreshID,
            locale: locale,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            reduceMotion: reduceMotion || reduceMotionOverride,
            sceneIsActive: scenePhase == .active,
            rowRevision: rowRevision,
            interactionRevision: interactionRevision,
            prepareUpdate: prepareUpdate,
            onViewportChange: onViewportChange,
            onTap: onTap
        )
    }

    static func dismantleUIView(_: ListView<Item>, coordinator: Coordinator) {
        coordinator.cancelRefresh()
        coordinator.stopObservingViewport()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        typealias Renderer = @MainActor (Item) -> AnyView

        private var items: [Item] = []
        private var renderer: Renderer?
        private var onSelect: ((Item) -> Void)?
        private var onRefresh: (() async -> Void)?
        private var refreshTask: Task<Void, Never>?
        private weak var refreshControl: UIRefreshControl?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var dynamicTypeSize = DynamicTypeSize.large
        private var refreshID: AnyHashable = 0
        private var reduceMotion = false
        private var sceneIsActive = true
        private var revisions: [Item.ID: UInt64] = [:]
        private var interactionRevisions: [Item.ID: UInt64] = [:]
        private var configuredIDsDuringUpdate: Set<Item.ID>?
        private var onViewportChange: ((Set<Item.ID>) -> Void)?
        private var onTap: (() -> Void)?
        private weak var listView: ListView<Item>?
        private var observations: [NSKeyValueObservation] = []
        private var viewportCheckScheduled = false

        func observeViewport(of view: ListView<Item>) {
            listView = view
            observations = [
                view.observe(\.bounds) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleViewportCheck() }
                },
                view.observe(\.contentSize) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleViewportCheck() }
                },
            ]
        }

        func installTapRecognizer(on view: ListView<Item>) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(listTapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
        }

        func stopObservingViewport() {
            observations.removeAll()
            onViewportChange = nil
            onTap = nil
            listView = nil
        }

        private func visibleIDs(in view: ListView<Item>) -> Set<Item.ID> {
            Set(view.indicesForVisibleRows.compactMap { items.indices.contains($0) ? items[$0].id : nil })
        }

        private func scheduleViewportCheck() {
            guard !viewportCheckScheduled else { return }
            viewportCheckScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                viewportCheckScheduled = false
                guard let view = listView else { return }
                onViewportChange?(visibleIDs(in: view))
            }
        }

        func update(
            listView: ListView<Item>, items newItems: [Item], renderer: @escaping Renderer,
            onSelect: ((Item) -> Void)?,
            onRefresh: (() async -> Void)?,
            followsBottom: Bool,
            surface: MobileNativeListSurface,
            refreshID newRefreshID: AnyHashable,
            locale: Locale, colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize,
            reduceMotion: Bool = false,
            sceneIsActive: Bool = true,
            rowRevision: ((Item) -> UInt64)? = nil,
            interactionRevision: ((Item) -> UInt64)? = nil,
            prepareUpdate: (([Item], [Item], Set<Item.ID>) -> Void)? = nil,
            onViewportChange: ((Set<Item.ID>) -> Void)? = nil,
            onTap: (() -> Void)? = nil
        ) {
            configuredIDsDuringUpdate = interactionRevision == nil ? nil : []
            defer { configuredIDsDuringUpdate = nil }
            let wasEmpty = items.isEmpty
            let wasAtBottom = wasEmpty || listView.isScrolledToBottom(tolerance: 48)
            let environmentChanged =
                self.locale != locale || self.colorScheme != colorScheme
                || self.dynamicTypeSize != dynamicTypeSize || refreshID != newRefreshID
                || self.reduceMotion != reduceMotion || self.sceneIsActive != sceneIsActive
            self.renderer = renderer
            self.onSelect = onSelect
            self.onRefresh = onRefresh
            self.onViewportChange = onViewportChange
            self.onTap = onTap
            self.locale = locale
            self.colorScheme = colorScheme
            self.dynamicTypeSize = dynamicTypeSize
            self.reduceMotion = reduceMotion
            self.sceneIsActive = sceneIsActive
            refreshID = newRefreshID
            listView.backgroundColor = surface.listBackground
            updateRefreshControl(in: listView)
            prepareUpdate?(items, newItems, visibleIDs(in: listView))

            let newRevisions = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, rowRevision?($0) ?? 0) })
            let newInteractionRevisions =
                interactionRevision.map { revision in
                    Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, revision($0)) })
                } ?? [:]
            let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let changed = newItems.filter {
                previous[$0.id] != $0 || revisions[$0.id] != newRevisions[$0.id]
            }
            let identitiesChanged = items.map(\.id) != newItems.map(\.id)
            if identitiesChanged {
                if !wasEmpty, newItems.count >= items.count,
                    newItems.prefix(items.count).map(\.id) == items.map(\.id)
                {
                    listView.append(contentsOf: Array(newItems.dropFirst(items.count)))
                } else {
                    listView.apply(newItems, animated: !wasEmpty && !reduceMotion)
                }
            }
            // A disclosure can change geometry without changing the item value.
            for item in changed where previous[item.id] != nil {
                if !listView.update(item), let row = listView.rowView(for: item.id) as? MobileHostingListRow {
                    configure(row, item: item, surface: surface)
                }
                listView.invalidateLayout(forRowWith: item.id)
            }
            if environmentChanged { listView.reloadData() }
            // Interaction-only updates retain the host and its measured geometry. Reconciliation
            // may already have configured a row with the latest renderer, so do not configure twice.
            if interactionRevision != nil, !environmentChanged {
                for item in newItems
                where interactionRevisions[item.id] != newInteractionRevisions[item.id]
                    && configuredIDsDuringUpdate?.contains(item.id) != true
                {
                    if let row = listView.rowView(for: item.id) as? MobileHostingListRow {
                        configure(row, item: item, surface: surface)
                    }
                }
            }
            items = newItems
            revisions = newRevisions
            interactionRevisions = newInteractionRevisions
            scheduleViewportCheck()
            if followsBottom, wasAtBottom, identitiesChanged || !changed.isEmpty {
                DispatchQueue.main.async { [weak listView] in
                    guard let listView, !listView.isUserInteractingWithScroll else { return }
                    listView.layoutIfNeeded()
                    listView.scrollToBottom(animated: !wasEmpty && !reduceMotion)
                }
            }
        }

        func cancelRefresh() {
            refreshTask?.cancel()
            refreshTask = nil
            refreshControl?.endRefreshing()
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func listTapped() { onTap?() }

        private func updateRefreshControl(in listView: ListView<Item>) {
            if onRefresh == nil {
                cancelRefresh()
                listView.refreshControl = nil
                refreshControl = nil
                return
            }
            guard listView.refreshControl == nil else { return }
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
            listView.refreshControl = control
            refreshControl = control
        }

        @objc private func refreshRequested() {
            guard refreshTask == nil, let onRefresh else {
                refreshControl?.endRefreshing()
                return
            }
            refreshTask = Task { [weak self] in
                await onRefresh()
                guard let self else { return }
                refreshControl?.endRefreshing()
                refreshTask = nil
            }
        }

        func configure(_ row: MobileHostingListRow, item: Item, surface: MobileNativeListSurface) {
            configuredIDsDuringUpdate?.insert(item.id)
            row.configure(
                rootView: rootView(for: item),
                selectable: onSelect != nil,
                backgroundColor: surface.rowBackground
            )
        }

        func configurePrototype(_ row: MobileHostingListRow, item: Item, surface: MobileNativeListSurface) {
            row.configure(
                rootView: rootView(for: item, displayed: false), selectable: false,
                backgroundColor: surface.rowBackground)
        }

        private func rootView(for item: Item, displayed: Bool = true) -> AnyView {
            guard let renderer else { return AnyView(EmptyView()) }
            let content = AnyView(
                renderer(item)
                    .environment(\.locale, locale)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.mobileListReduceMotion, reduceMotion)
                    .environment(\.mobileListSceneIsActive, sceneIsActive)
                    .environment(\.mobileListRowIsDisplayed, displayed)
                    .id(item.id)
            )
            guard displayed, let onSelect else { return content }
            return AnyView(content.onTapGesture { onSelect(item) })
        }
    }
}

@MainActor
final class MobileHostingListRow: ListRowView, UIGestureRecognizerDelegate {
    private let contentContainer = UIView()
    private var hostedView: UIView?
    private var selectable = false
    private var pressOrigin: CGPoint?
    private var restingBackgroundColor = UIColor.clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear

        contentContainer.backgroundColor = .clear
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let press = UILongPressGestureRecognizer(target: self, action: #selector(rowPressed(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delegate = self
        contentContainer.addGestureRecognizer(press)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostedView?.removeFromSuperview()
        hostedView = nil
        selectable = false
        pressOrigin = nil
        restingBackgroundColor = .clear
        backgroundColor = .clear
        contentContainer.backgroundColor = .clear
    }

    func configure(rootView: AnyView, selectable: Bool, backgroundColor: UIColor) {
        restingBackgroundColor = backgroundColor
        self.backgroundColor = backgroundColor
        contentContainer.backgroundColor = backgroundColor
        let configuration = UIHostingConfiguration {
            rootView
        }
        .margins(.all, 0)
        .background(.clear)
        if let contentView = hostedView as? any UIContentView {
            contentView.configuration = configuration
            self.selectable = selectable
            return
        }
        let hostedView = configuration.makeContentView()
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        self.hostedView = hostedView
        self.selectable = selectable
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer { return selectable }
        return true
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func rowPressed(_ recognizer: UILongPressGestureRecognizer) {
        let isPressed: Bool
        switch recognizer.state {
        case .began:
            pressOrigin = recognizer.location(in: contentContainer)
            isPressed = true
        case .changed:
            let location = recognizer.location(in: contentContainer)
            let distance = pressOrigin.map { hypot(location.x - $0.x, location.y - $0.y) } ?? .infinity
            isPressed = distance < 10 && contentContainer.bounds.insetBy(dx: -12, dy: -12).contains(location)
        default:
            pressOrigin = nil
            isPressed = false
        }
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.contentContainer.backgroundColor =
                isPressed ? .tertiarySystemFill : self.restingBackgroundColor
        }
    }

}
