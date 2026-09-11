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
    @ViewBuilder let rowContent: (Item) -> RowContent

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    init(
        items: [Item], estimatedRowHeight: CGFloat = 72, refreshID: AnyHashable = 0,
        onSelect: ((Item) -> Void)? = nil,
        onDelete: ((Item) -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.estimatedRowHeight = estimatedRowHeight
        self.refreshID = refreshID
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.rowContent = rowContent
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ListView<Item> {
        let listView = ListView<Item>()
        let coordinator = context.coordinator
        listView.backgroundColor = .clear
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
            refreshID: refreshID,
            locale: locale,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    @MainActor
    final class Coordinator {
        typealias Renderer = @MainActor (Item) -> AnyView

        private var items: [Item] = []
        private var renderer: Renderer?
        private var onSelect: ((Item) -> Void)?
        private var onDelete: ((Item) -> Void)?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var dynamicTypeSize = DynamicTypeSize.large
        private var refreshID: AnyHashable = 0

        @_optimize(none) deinit {}

        func update(
            listView: ListView<Item>, items newItems: [Item], renderer: @escaping Renderer,
            onSelect: ((Item) -> Void)?, onDelete: ((Item) -> Void)?,
            refreshID newRefreshID: AnyHashable,
            locale: Locale, colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize
        ) {
            let environmentChanged =
                self.locale != locale || self.colorScheme != colorScheme
                || self.dynamicTypeSize != dynamicTypeSize || refreshID != newRefreshID
            self.renderer = renderer
            self.onSelect = onSelect
            self.onDelete = onDelete
            self.locale = locale
            self.colorScheme = colorScheme
            self.dynamicTypeSize = dynamicTypeSize
            refreshID = newRefreshID

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
        }

        func configure(_ row: MobileHostingListRow, item: Item) {
            row.configure(
                rootView: rootView(for: item),
                onSelect: onSelect.map { action in { action(item) } },
                onDelete: onDelete.map { action in { action(item) } }
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
    static let deleteWidth: CGFloat = 88

    private let contentContainer = UIView()
    private let deleteButton = UIButton(type: .system)
    private var hostedView: UIView?
    private var onSelect: (() -> Void)?
    private var onDelete: (() -> Void)?
    private var revealOffset: CGFloat = 0
    private var panStartOffset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true

        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Delete")
        configuration.image = UIImage(systemName: "trash")
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        deleteButton.configuration = configuration
        deleteButton.addTarget(self, action: #selector(deletePressed), for: .touchUpInside)
        addSubview(deleteButton)

        contentContainer.backgroundColor = .systemBackground
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
        contentContainer.addGestureRecognizer(tap)

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
        contentContainer.transform = .identity
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
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard onDelete != nil else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) && (velocity.x < 0 || revealOffset < 0)
    }

    @objc private func rowTapped() {
        guard revealOffset == 0 else {
            setRevealOffset(0, animated: true)
            return
        }
        onSelect?()
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
