import AppKit
import ListViewKit
import Observation
import SwiftUI

/// The stable list item handed to ListViewKit. Empty and interrupted states are
/// rows as well, so every transcript state follows the same sizing and scrolling
/// path instead of layering SwiftUI content over the native list.
nonisolated struct TranscriptRenderItem: Identifiable, Hashable, Sendable {
    nonisolated enum Content: Hashable, Sendable {
        case timeline(TimelineItem)
        case empty
        case interrupted
    }

    let id: UUID
    let content: Content
    let hasLeadingSpacing: Bool

    init(id: UUID, content: Content, hasLeadingSpacing: Bool = false) {
        self.id = id
        self.content = content
        self.hasLeadingSpacing = hasLeadingSpacing
    }

    private static let emptyID = UUID(uuidString: "00E48921-70E7-493A-9EB3-44727BC2145B")!
    private static let interruptedID = UUID(uuidString: "FD8D34B6-E81F-4DC8-91E8-479AD9ACF5CB")!

    static func items(timeline: [TimelineItem], isInterrupted: Bool) -> [Self] {
        if timeline.isEmpty {
            return [.init(id: emptyID, content: .empty)]
        }
        var result = timeline.enumerated().map { index, item in
            Self(
                id: item.id,
                content: .timeline(item),
                hasLeadingSpacing: index > 0
            )
        }
        if isInterrupted {
            result.append(.init(
                id: interruptedID,
                content: .interrupted,
                hasLeadingSpacing: true
            ))
        }
        return result
    }

    /// Disclosure and editing state can also belong to rows nested inside a
    /// work group. Keeping their IDs here lets a surface discard state only
    /// after the corresponding transcript content really disappears.
    var presentationIDs: Set<UUID> {
        guard case .timeline(let item) = content else { return [] }
        var result: Set<UUID> = [item.id]
        guard case .work(let group) = item else { return result }
        for workItem in group.items {
            result.insert(workItem.id)
            if case .tools(let batch) = workItem {
                result.formUnion(batch.cards.map(\.id))
            }
        }
        return result
    }
}

/// Row interaction state must outlive a recycled NSHostingView. It belongs to
/// one transcript surface: the compact sidebar and full Assistant may show the
/// same conversation without forcing one another's disclosures open.
@MainActor
@Observable
final class TranscriptPresentationState {
    private struct DisclosureState {
        var isExpanded: Bool
        var readerDidToggle: Bool
    }

    private var disclosureStates: [UUID: DisclosureState] = [:]
    private struct MessageEditState {
        var isEditing = false
        var text = ""
        var bubbleWidth: CGFloat = 0
    }

    private var messageEdits: [UUID: MessageEditState] = [:]

    func isExpanded(_ id: UUID, default defaultValue: Bool = false) -> Bool {
        disclosureStates[id]?.isExpanded ?? defaultValue
    }

    func readerDidToggle(_ id: UUID) -> Bool {
        disclosureStates[id]?.readerDidToggle == true
    }

    func toggleDisclosure(_ id: UUID, default defaultValue: Bool = false) {
        let current = disclosureStates[id]?.isExpanded ?? defaultValue
        disclosureStates[id] = .init(isExpanded: !current, readerDidToggle: true)
    }

    func followDefault(_ expanded: Bool, for id: UUID) {
        guard disclosureStates[id]?.readerDidToggle != true else { return }
        disclosureStates[id] = .init(isExpanded: expanded, readerDidToggle: false)
    }

    func prune(validTimelineIDs: Set<UUID>) {
        disclosureStates = disclosureStates.filter { validTimelineIDs.contains($0.key) }
        messageEdits = messageEdits.filter { validTimelineIDs.contains($0.key) }
    }

    func isEditingMessage(_ id: UUID) -> Bool {
        messageEdits[id]?.isEditing == true
    }

    func messageEditText(_ id: UUID) -> String {
        messageEdits[id]?.text ?? ""
    }

    func messageBubbleWidth(_ id: UUID) -> CGFloat {
        messageEdits[id]?.bubbleWidth ?? 0
    }

    func beginEditingMessage(_ id: UUID, text: String) {
        var state = messageEdits[id] ?? .init()
        state.isEditing = true
        state.text = text
        messageEdits[id] = state
    }

    func endEditingMessage(_ id: UUID) {
        var state = messageEdits[id] ?? .init()
        state.isEditing = false
        messageEdits[id] = state
    }

    func setMessageEditText(_ text: String, for id: UUID) {
        var state = messageEdits[id] ?? .init()
        state.text = text
        messageEdits[id] = state
    }

    func setMessageBubbleWidth(_ width: CGFloat, for id: UUID) {
        var state = messageEdits[id] ?? .init()
        state.bubbleWidth = width
        messageEdits[id] = state
    }

    func messageEditBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.messageEditText(id) ?? "" },
            set: { [weak self] in self?.setMessageEditText($0, for: id) }
        )
    }
}

nonisolated struct TranscriptListUpdatePlan: Equatable, Sendable {
    var replacesAll = false
    var updates: [TranscriptRenderItem] = []
    var appends: [TranscriptRenderItem] = []

    static func make(
        old: [TranscriptRenderItem], new: [TranscriptRenderItem]
    ) -> Self {
        guard !old.isEmpty else { return .init(replacesAll: true) }
        let sharedCount = min(old.count, new.count)
        let oldSharedIDs = old.prefix(sharedCount).map(\.id)
        let newSharedIDs = new.prefix(sharedCount).map(\.id)
        guard oldSharedIDs == newSharedIDs, new.count >= old.count else {
            return .init(replacesAll: true)
        }

        return .init(
            updates: zip(old, new).compactMap { $0 == $1 ? nil : $1 },
            appends: Array(new.dropFirst(old.count))
        )
    }
}

/// SwiftUI ownership outside, AppKit virtualization inside. The representable
/// deliberately exposes only content and rendering; ListViewKit never leaks into
/// the rest of the Assistant feature.
struct TranscriptListView: NSViewRepresentable {
    typealias NSViewType = ListView<TranscriptRenderItem>
    typealias Renderer = @MainActor (
        TranscriptRenderItem, @escaping @MainActor () -> Void
    ) -> AnyView

    let items: [TranscriptRenderItem]
    let latestUserMessageID: UUID?
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeListView()
    }

    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView,
            items: items,
            latestUserMessageID: latestUserMessageID,
            renderer: renderer,
            environment: .init(
                locale: locale,
                colorScheme: colorScheme
            )
        )
    }

    @MainActor
    final class Coordinator {
        struct EnvironmentSnapshot {
            let locale: Locale
            let colorScheme: ColorScheme
        }

        private var renderer: Renderer?
        private var environment: EnvironmentSnapshot?
        private var content: [TranscriptRenderItem] = []
        private var latestUserMessageID: UUID?
        private weak var listView: NSViewType?
        private var pendingInvalidations: Set<UUID> = []
        private var pendingInvalidationMayFollow = false
        private var invalidationScheduled = false
        private var disclosureSuppressedUntil: [UUID: UInt64] = [:]
        private let measurementController = NSHostingController(
            rootView: AnyView(EmptyView())
        )

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            self.listView = listView
            listView.estimatedRowHeight = 96
            listView.topInset = Metrics.Space.xl
            listView.bottomInset = Metrics.Space.xl
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.rows {
                ListRow(TranscriptHostingRow.self)
                    .estimatedHeight(96)
                    .height { [weak self] item, context in
                        self?.measuredHeight(for: item, width: context.width) ?? 96
                    }
                    .configure { [weak self] row, item, context in
                        self?.configure(row, with: item, purpose: context.purpose)
                    }
            }
            return listView
        }

        func update(
            listView: NSViewType,
            items newItems: [TranscriptRenderItem],
            latestUserMessageID newLatestUserMessageID: UUID?,
            renderer: @escaping Renderer,
            environment: EnvironmentSnapshot
        ) {
            self.renderer = renderer
            self.environment = environment

            let isFirstUpdate = content.isEmpty
            let userSentMessage = latestUserMessageID != nil
                && latestUserMessageID != newLatestUserMessageID
            let shouldFollow = isFirstUpdate || userSentMessage
                || (listView.isScrolledToBottom(tolerance: Metrics.Space.l)
                    && !listView.isUserInteractingWithScroll)

            let plan = TranscriptListUpdatePlan.make(old: content, new: newItems)
            if plan.replacesAll {
                listView.apply(newItems)
            } else {
                for item in plan.updates { listView.update(item) }
                if !plan.appends.isEmpty { listView.append(contentsOf: plan.appends) }
            }
            content = newItems
            latestUserMessageID = newLatestUserMessageID

            guard shouldFollow else { return }
            DispatchQueue.main.async { [weak listView] in
                guard let listView, !listView.isUserInteractingWithScroll else { return }
                listView.scrollToBottom(animated: false)
            }
        }

        private func configure(
            _ row: TranscriptHostingRow,
            with item: TranscriptRenderItem,
            purpose: ListRowPurpose
        ) {
            guard let renderer, let environment else { return }
            let disclosureToggle: @MainActor () -> Void = { [weak self] in
                self?.suppressFollowing(for: item.id)
                self?.invalidate(item.id, mayFollow: false)
            }
            let content = renderer(item, disclosureToggle)
                .environment(\.locale, environment.locale)
                .environment(\.colorScheme, environment.colorScheme)
            let sizeChange: (@MainActor () -> Void)?
            switch purpose {
            case .display:
                sizeChange = { [weak self] in
                    guard let self else { return }
                    self.invalidate(
                        item.id,
                        mayFollow: !self.isFollowingSuppressed(for: item.id)
                    )
                }
            case .measurement:
                sizeChange = nil
            }
            row.configure(
                id: item.id,
                rootView: AnyView(content),
                onIntrinsicSizeChange: sizeChange
            )
        }

        private func measuredHeight(
            for item: TranscriptRenderItem,
            width: CGFloat
        ) -> CGFloat {
            guard let renderer, let environment, width > 0 else { return 96 }
            let content = renderer(item, {})
                .environment(\.locale, environment.locale)
                .environment(\.colorScheme, environment.colorScheme)
            measurementController.rootView = AnyView(content)
            return ceil(measurementController.sizeThatFits(in: CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            )).height)
        }

        private func suppressFollowing(for id: UUID) {
            disclosureSuppressedUntil[id] = DispatchTime.now().uptimeNanoseconds
                + 250_000_000
        }

        private func isFollowingSuppressed(for id: UUID) -> Bool {
            guard let deadline = disclosureSuppressedUntil[id] else { return false }
            if DispatchTime.now().uptimeNanoseconds < deadline { return true }
            disclosureSuppressedUntil[id] = nil
            return false
        }

        private func invalidate(_ id: UUID, mayFollow: Bool) {
            pendingInvalidations.insert(id)
            pendingInvalidationMayFollow = pendingInvalidationMayFollow || mayFollow
            guard !invalidationScheduled else { return }
            invalidationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.invalidationScheduled = false
                let ids = self.pendingInvalidations
                self.pendingInvalidations.removeAll()
                let listView = self.listView
                let shouldFollow = self.pendingInvalidationMayFollow
                    && listView?.isScrolledToBottom(tolerance: Metrics.Space.l) == true
                    && listView?.isUserInteractingWithScroll == false
                self.pendingInvalidationMayFollow = false
                for id in ids {
                    listView?.invalidateLayout(forRowWith: id)
                }
                if shouldFollow {
                    DispatchQueue.main.async { [weak listView] in
                        guard let listView, !listView.isUserInteractingWithScroll else { return }
                        listView.scrollToBottom(animated: false)
                    }
                }
            }
        }
    }
}

@MainActor
private final class TranscriptHostingRow: ListRowView {
    private let hostingView = TranscriptIntrinsicHostingView(rootView: AnyView(EmptyView()))
    private var representedID: UUID?

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
        representedID = nil
        hostingView.onIntrinsicSizeChange = nil
        hostingView.rootView = AnyView(EmptyView())
    }

    func configure(
        id: UUID,
        rootView: AnyView,
        onIntrinsicSizeChange: (@MainActor () -> Void)?
    ) {
        representedID = id
        hostingView.onIntrinsicSizeChange = onIntrinsicSizeChange
        hostingView.rootView = rootView
    }
}

@MainActor
private final class TranscriptIntrinsicHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (@MainActor () -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard let onIntrinsicSizeChange else { return }
        DispatchQueue.main.async(execute: onIntrinsicSizeChange)
    }
}
