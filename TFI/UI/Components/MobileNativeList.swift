import ListViewKit
import SwiftUI
import UIKit

struct MobileNativeList<Item, RowContent>: UIViewRepresentable
where Item: Identifiable & Hashable & SendableMetatype, RowContent: View {
    typealias UIViewType = ListView<Item>

    let items: [Item]
    let estimatedRowHeight: CGFloat
    let refreshID: AnyHashable
    let onSelect: ((Item) -> Void)?
    let onDelete: ((Item) -> Void)?
    let canDelete: (Item) -> Bool
    let onRefresh: (() async -> Void)?
    let followsBottom: Bool
    @ViewBuilder let rowContent: (Item) -> RowContent

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    init(
        items: [Item], estimatedRowHeight: CGFloat = 72, refreshID: AnyHashable = 0,
        onSelect: ((Item) -> Void)? = nil,
        onDelete: ((Item) -> Void)? = nil,
        canDelete: @escaping (Item) -> Bool = { _ in true },
        onRefresh: (() async -> Void)? = nil,
        followsBottom: Bool = false,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.estimatedRowHeight = estimatedRowHeight
        self.refreshID = refreshID
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.canDelete = canDelete
        self.onRefresh = onRefresh
        self.followsBottom = followsBottom
        self.rowContent = rowContent
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ListView<Item> {
        let listView = ListView<Item>()
        let coordinator = context.coordinator
        listView.backgroundColor = .systemGroupedBackground
        listView.estimatedRowHeight = estimatedRowHeight
        listView.keyboardDismissMode = .interactive
        listView.rows {
            ListRow(MobileHostingListRow.self)
                .estimatedHeight(estimatedRowHeight)
                .configure { row, item, rowContext in
                    if rowContext.purpose == .display {
                        coordinator.configure(row, item: item)
                    } else {
                        coordinator.configurePrototype(row, item: item)
                    }
                }
        }
        return listView
    }

    func updateUIView(_ listView: ListView<Item>, context: Context) {
        context.coordinator.update(
            listView: listView,
            items: items,
            renderer: { item in AnyView(rowContent(item)) },
            onSelect: onSelect,
            onDelete: onDelete,
            canDelete: canDelete,
            onRefresh: onRefresh,
            followsBottom: followsBottom,
            refreshID: refreshID,
            locale: locale,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    static func dismantleUIView(_: ListView<Item>, coordinator: Coordinator) {
        coordinator.cancelRefresh()
    }

    @MainActor
    final class Coordinator: NSObject {
        typealias Renderer = @MainActor (Item) -> AnyView

        private var items: [Item] = []
        private var renderer: Renderer?
        private var onSelect: ((Item) -> Void)?
        private var onDelete: ((Item) -> Void)?
        private var canDelete: (Item) -> Bool = { _ in true }
        private var onRefresh: (() async -> Void)?
        private var refreshTask: Task<Void, Never>?
        private weak var refreshControl: UIRefreshControl?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var dynamicTypeSize = DynamicTypeSize.large
        private var refreshID: AnyHashable = 0

        @_optimize(none) deinit {}

        func update(
            listView: ListView<Item>, items newItems: [Item], renderer: @escaping Renderer,
            onSelect: ((Item) -> Void)?, onDelete: ((Item) -> Void)?,
            canDelete: @escaping (Item) -> Bool,
            onRefresh: (() async -> Void)?,
            followsBottom: Bool,
            refreshID newRefreshID: AnyHashable,
            locale: Locale, colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize
        ) {
            let wasAtBottom =
                items.isEmpty
                || listView.contentSize.height - listView.bounds.height
                    - listView.contentOffset.y <= 48
            let environmentChanged =
                self.locale != locale || self.colorScheme != colorScheme
                || self.dynamicTypeSize != dynamicTypeSize || refreshID != newRefreshID
            self.renderer = renderer
            self.onSelect = onSelect
            self.onDelete = onDelete
            self.canDelete = canDelete
            self.onRefresh = onRefresh
            self.locale = locale
            self.colorScheme = colorScheme
            self.dynamicTypeSize = dynamicTypeSize
            refreshID = newRefreshID
            updateRefreshControl(in: listView)

            let identitiesChanged = items.map(\.id) != newItems.map(\.id)
            if identitiesChanged {
                listView.apply(newItems, animated: !items.isEmpty)
            } else {
                for (old, new) in zip(items, newItems) where old != new {
                    listView.update(new)
                }
                if environmentChanged { listView.reloadData() }
            }
            items = newItems
            if followsBottom, wasAtBottom {
                Task { @MainActor in listView.scrollToBottom(animated: !self.items.isEmpty) }
            }
        }

        func cancelRefresh() {
            refreshTask?.cancel()
            refreshTask = nil
            refreshControl?.endRefreshing()
        }

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

        func configure(_ row: MobileHostingListRow, item: Item) {
            row.configure(
                rootView: rootView(for: item),
                onSelect: onSelect.map { action in { action(item) } },
                onDelete: canDelete(item) ? onDelete.map { action in { action(item) } } : nil
            )
        }

        func configurePrototype(_ row: MobileHostingListRow, item: Item) {
            row.configure(rootView: rootView(for: item), onSelect: nil, onDelete: nil)
        }

        private func rootView(for item: Item) -> AnyView {
            guard let renderer else { return AnyView(EmptyView()) }
            return AnyView(
                renderer(item)
                    .environment(\.locale, locale)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .id(item.id)
            )
        }
    }
}

@MainActor
final class MobileHostingListRow: ListRowView, UIGestureRecognizerDelegate {
    static let deleteWidth: CGFloat = 72

    private let contentContainer = UIView()
    private let deleteButton = UIButton(type: .system)
    private var hostedView: UIView?
    private var onSelect: (() -> Void)?
    private var onDelete: (() -> Void)?
    private var revealOffset: CGFloat = 0
    private var panStartOffset: CGFloat = 0
    private var pressOrigin: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .secondarySystemGroupedBackground

        deleteButton.setImage(UIImage(systemName: "trash"), for: .normal)
        deleteButton.tintColor = .white
        deleteButton.backgroundColor = .systemRed
        deleteButton.accessibilityLabel = String(localized: "Delete")
        deleteButton.addTarget(self, action: #selector(deletePressed), for: .touchUpInside)
        addSubview(deleteButton)

        contentContainer.backgroundColor = .secondarySystemGroupedBackground
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        contentContainer.addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(rowPressed(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delegate = self
        contentContainer.addGestureRecognizer(press)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(rowPanned(_:)))
        pan.delegate = self
        contentContainer.addGestureRecognizer(pan)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostedView?.removeFromSuperview()
        hostedView = nil
        onSelect = nil
        onDelete = nil
        revealOffset = 0
        panStartOffset = 0
        pressOrigin = nil
        contentContainer.transform = .identity
        contentContainer.backgroundColor = .secondarySystemGroupedBackground
        deleteButton.isHidden = true
        deleteButton.accessibilityElementsHidden = true
        accessibilityCustomActions = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        deleteButton.frame = CGRect(
            x: bounds.maxX - Self.deleteWidth, y: bounds.minY,
            width: Self.deleteWidth, height: bounds.height)
        contentContainer.transform = CGAffineTransform(translationX: revealOffset, y: 0)
    }

    func configure(rootView: AnyView, onSelect: (() -> Void)?, onDelete: (() -> Void)?) {
        hostedView?.removeFromSuperview()
        let hostedView = UIHostingConfiguration {
            rootView
        }
        .margins(.all, 0)
        .background(.clear)
        .makeContentView()
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        self.hostedView = hostedView
        self.onSelect = onSelect
        self.onDelete = onDelete
        deleteButton.isHidden = onDelete == nil
        deleteButton.accessibilityElementsHidden = onDelete == nil
        let deleteActions = onDelete.map { action in
            [
                UIAccessibilityCustomAction(name: String(localized: "Delete")) { _ in
                    action()
                    return true
                }
            ]
        }
        accessibilityCustomActions = deleteActions
        hostedView.accessibilityCustomActions = deleteActions
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer { return onSelect != nil }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard onDelete != nil else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) && (velocity.x < 0 || revealOffset < 0)
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func rowTapped() {
        guard revealOffset == 0 else {
            setRevealOffset(0, animated: true)
            return
        }
        onSelect?()
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
                isPressed ? .tertiarySystemFill : .secondarySystemGroupedBackground
        }
    }

    @objc private func rowPanned(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            panStartOffset = revealOffset
        case .changed:
            let translation = recognizer.translation(in: self).x
            setRevealOffset(min(0, max(-Self.deleteWidth, panStartOffset + translation)), animated: false)
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: self).x
            let shouldReveal = velocity < -250 || (velocity <= 250 && revealOffset < -Self.deleteWidth / 2)
            setRevealOffset(shouldReveal ? -Self.deleteWidth : 0, animated: true)
        default:
            break
        }
    }

    @objc private func deletePressed() { onDelete?() }

    private func setRevealOffset(_ value: CGFloat, animated: Bool) {
        revealOffset = value
        let changes = {
            self.contentContainer.transform = CGAffineTransform(translationX: value, y: 0)
        }
        if animated {
            UIView.animate(
                withDuration: 0.22, delay: 0,
                usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }
}
