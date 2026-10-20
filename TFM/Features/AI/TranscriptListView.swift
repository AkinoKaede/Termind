// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import ListViewKit
import Observation
import SwiftUI
import TermindApplication
import TermindPresentation

typealias TranscriptEntry = AssistantTranscriptEntry

@MainActor
@Observable
final class TranscriptPresentationState {
    let disclosures = AssistantTranscriptPresentationState()

    private struct MessageEditState {
        var isEditing = false
        var text = ""
        var bubbleWidth: CGFloat = 0
        var revision: UInt64 = 0
    }

    private var messageEdits: [UUID: MessageEditState] = [:]
    private var nextRevision: UInt64 = 1

    func prune(validTimelineIDs: Set<UUID>) {
        disclosures.prune(validTimelineIDs: validTimelineIDs)
        for id in messageEdits.keys where !validTimelineIDs.contains(id) { messageEdits[id] = nil }
    }

    func isEditingMessage(_ id: UUID) -> Bool { messageEdits[id]?.isEditing == true }
    func messageEditText(_ id: UUID) -> String { messageEdits[id]?.text ?? "" }
    func messageBubbleWidth(_ id: UUID) -> CGFloat { messageEdits[id]?.bubbleWidth ?? 0 }
    func beginEditingMessage(_ id: UUID, text: String) {
        var state = messageEdits[id] ?? .init()
        state.isEditing = true
        state.text = text
        state.revision = takeRevision()
        messageEdits[id] = state
    }
    func endEditingMessage(_ id: UUID) {
        var state = messageEdits[id] ?? .init()
        state.isEditing = false
        state.revision = takeRevision()
        messageEdits[id] = state
    }
    func setMessageEditText(_ text: String, for id: UUID) {
        var state = messageEdits[id] ?? .init()
        state.text = text
        state.revision = takeRevision()
        messageEdits[id] = state
    }
    func setMessageBubbleWidth(_ width: CGFloat, for id: UUID) {
        var state = messageEdits[id] ?? .init()
        guard abs(state.bubbleWidth - width) > 0.5 else { return }
        state.bubbleWidth = width
        state.revision = takeRevision()
        messageEdits[id] = state
    }
    func layoutRevision(for ids: Set<UUID>) -> UInt64 {
        ids.reduce(disclosures.layoutRevision(for: ids)) { result, id in
            result &+ (messageEdits[id]?.revision ?? 0)
        }
    }
    private func takeRevision() -> UInt64 {
        defer { nextRevision &+= 1 }
        return nextRevision
    }
}

nonisolated struct TranscriptListUpdatePlan: Equatable, Sendable {
    var replacesAll = false
    var updates: [TranscriptEntry] = []
    var appends: [TranscriptEntry] = []

    static func make(old: [TranscriptEntry], new: [TranscriptEntry]) -> Self {
        guard !old.isEmpty else { return .init(replacesAll: true) }
        let count = min(old.count, new.count)
        guard old.prefix(count).map(\.id) == new.prefix(count).map(\.id), new.count >= old.count
        else { return .init(replacesAll: true) }
        return .init(
            updates: zip(old, new).compactMap { $0 == $1 ? nil : $1 },
            appends: Array(new.dropFirst(old.count))
        )
    }
}

@MainActor
struct TranscriptListConfiguration: Equatable {
    let isCompact: Bool
    let showsTerminalActions: Bool
    let isConversationStreaming: Bool
    let chatDestinations: [UUID: String]
    let locale: Locale
    let reduceMotion: Bool
    let colorScheme: ColorScheme
    var horizontalInset: CGFloat { isCompact ? Metrics.Space.l : Metrics.Space.xl }

    /// Run state and destination availability only affect existing controls.
    /// Keep all other configuration changes on the original reload path.
    func hasSameLayout(as other: Self) -> Bool {
        isCompact == other.isCompact && showsTerminalActions == other.showsTerminalActions
            && locale == other.locale && reduceMotion == other.reduceMotion && colorScheme == other.colorScheme
    }

    init(
        isCompact: Bool, showsTerminalActions: Bool, isConversationStreaming: Bool,
        chatDestinations: [UUID: String] = [:], locale: Locale, reduceMotion: Bool,
        colorScheme: ColorScheme
    ) {
        self.isCompact = isCompact
        self.showsTerminalActions = showsTerminalActions
        self.isConversationStreaming = isConversationStreaming
        self.chatDestinations = chatDestinations
        self.locale = locale
        self.reduceMotion = reduceMotion
        self.colorScheme = colorScheme
    }
}

@MainActor
struct TranscriptListActions {
    var hostName: (UUID) -> String? = { _ in nil }
    var navigateChat: (UUID) -> Void = { _ in }
    var editUserMessage: (UUID, String) -> Void = { _, _ in }
    var forkAssistantMessage: (UUID) -> Void = { _ in }
    var resolvePlan: (UUID, AgentPlan.Outcome) -> Void = { _, _ in }
    var implementPlan: (AgentPlanCard) -> Void = { _ in }
    var canDeliverCommand: () -> Bool = { false }
    var deliverCommand: (String, Bool) -> Void = { _, _ in }
}

/// The two places that may render one conversation at the same time.
///
/// AppKit views have one superview, so full-screen Assistant and the Workspace
/// sidebar must never share a cached list even when they show the same chat.
nonisolated enum TranscriptSurface: Hashable, Sendable {
    case fullScreen
    case sidebar
}

nonisolated struct TranscriptCacheKey: Hashable, Sendable {
    let conversationID: UUID
    let surface: TranscriptSurface
}

/// One long-lived native transcript and the presentation state measured with it.
///
/// SwiftUI owns only the short-lived mount container. The owner lives in the
/// window cache, so removing Assistant from the destination tree preserves the
/// list's content offset, measured row heights, and Markdown cache without
/// asking a hidden page to keep participating in layout.
@MainActor
final class PersistentTranscriptListOwner {
    let key: TranscriptCacheKey
    let coordinator = TranscriptListView.Coordinator()
    let presentation = TranscriptPresentationState()
    let listView: ListView<TranscriptEntry>

    private weak var container: TranscriptMountView?
    private var mountConstraints: [NSLayoutConstraint] = []
    private var nextMountOrdinal: UInt64 = 0
    private let didAccess: () -> Void
    private let didUnmount: () -> Void

    private var ownerIdentifier: ObjectIdentifier { ObjectIdentifier(self) }
    var isMounted: Bool { container != nil && listView.superview === container }

    init(
        key: TranscriptCacheKey,
        didAccess: @escaping () -> Void = {},
        didUnmount: @escaping () -> Void = {}
    ) {
        self.key = key
        self.didAccess = didAccess
        self.didUnmount = didUnmount
        listView = coordinator.makeListView()
        listView.translatesAutoresizingMaskIntoConstraints = false
    }

    func mount(in newContainer: TranscriptMountView) {
        assignOrdinalIfNeeded(to: newContainer)
        if let currentOrdinal = container?.mountOrdinals[ownerIdentifier],
            let proposedOrdinal = newContainer.mountOrdinals[ownerIdentifier],
            proposedOrdinal < currentOrdinal
        {
            return
        }

        didAccess()
        guard container !== newContainer || listView.superview !== newContainer else { return }
        if let displacedOwner = newContainer.owner, displacedOwner !== self {
            displacedOwner.unmount(from: newContainer)
        }
        NSLayoutConstraint.deactivate(mountConstraints)
        mountConstraints.removeAll(keepingCapacity: true)
        listView.removeFromSuperview()
        container?.owner = nil

        newContainer.owner = self
        newContainer.addSubview(listView)
        mountConstraints = [
            listView.leadingAnchor.constraint(equalTo: newContainer.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: newContainer.trailingAnchor),
            listView.topAnchor.constraint(equalTo: newContainer.topAnchor),
            listView.bottomAnchor.constraint(equalTo: newContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(mountConstraints)
        container = newContainer
    }

    func unmount(from oldContainer: TranscriptMountView) {
        guard container === oldContainer, listView.superview === oldContainer else { return }
        NSLayoutConstraint.deactivate(mountConstraints)
        mountConstraints.removeAll(keepingCapacity: true)
        listView.removeFromSuperview()
        oldContainer.owner = nil
        container = nil
        coordinator.suspend()
        didUnmount()
    }

    func update(
        entries: [TranscriptEntry],
        latestUserMessageID: UUID?,
        configuration: TranscriptListConfiguration,
        actions: TranscriptListActions
    ) {
        coordinator.update(
            listView: listView,
            entries: entries,
            latestUserMessageID: latestUserMessageID,
            configuration: configuration,
            actions: actions,
            presentation: presentation
        )
    }

    private func assignOrdinalIfNeeded(to container: TranscriptMountView) {
        guard container.mountOrdinals[ownerIdentifier] == nil else { return }
        nextMountOrdinal &+= 1
        container.mountOrdinals[ownerIdentifier] = nextMountOrdinal
    }
}

@MainActor
final class TranscriptMountView: NSView {
    weak var owner: PersistentTranscriptListOwner?
    fileprivate var mountOrdinals: [ObjectIdentifier: UInt64] = [:]
}

/// Window-local LRU of native transcript views.
///
/// FlowDown keeps one list per conversation. Vela additionally distinguishes
/// full-screen and sidebar surfaces and caps the combined cache, because each
/// transcript carries Markdown and row-sizing caches of its own.
@MainActor
final class TranscriptListCache {
    static let defaultLimit = 8

    private let limit: Int
    private var owners: [TranscriptCacheKey: PersistentTranscriptListOwner] = [:]
    private var order: [TranscriptCacheKey] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func owner(for key: TranscriptCacheKey) -> PersistentTranscriptListOwner {
        if let owner = owners[key] {
            touch(key)
            return owner
        }
        let owner = PersistentTranscriptListOwner(
            key: key,
            didAccess: { [weak self] in self?.touch(key) },
            didUnmount: { [weak self] in self?.trimIfNeeded() }
        )
        owners[key] = owner
        touch(key)
        trimIfNeeded(protecting: key)
        return owner
    }

    func removeConversation(_ id: UUID) {
        let keys = owners.keys.filter { $0.conversationID == id }
        guard !keys.isEmpty else { return }
        let removed = Set(keys)
        for key in keys { owners[key] = nil }
        order.removeAll { removed.contains($0) }
    }

    func removeAll() {
        owners.removeAll()
        order.removeAll()
    }

    func cachedOwner(for key: TranscriptCacheKey) -> PersistentTranscriptListOwner? {
        owners[key]
    }

    var count: Int { owners.count }

    private func touch(_ key: TranscriptCacheKey) {
        guard owners[key] != nil else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trimIfNeeded(protecting protectedKey: TranscriptCacheKey? = nil) {
        while owners.count > limit {
            guard
                let victim = order.first(where: { key in
                    key != protectedKey && owners[key]?.isMounted == false
                })
            else { return }
            owners[victim] = nil
            order.removeAll { $0 == victim }
        }
    }
}

struct TranscriptListView: NSViewRepresentable {
    typealias NSViewType = TranscriptMountView
    typealias NativeListView = ListView<TranscriptEntry>
    let owner: PersistentTranscriptListOwner
    let entries: [TranscriptEntry]
    let latestUserMessageID: UUID?
    let configuration: TranscriptListConfiguration
    let actions: TranscriptListActions

    func makeCoordinator() -> Coordinator { Coordinator(mountOwner: owner) }
    func makeNSView(context: Context) -> NSViewType {
        let container = TranscriptMountView()
        context.coordinator.mountOwner?.mount(in: container)
        return container
    }
    func updateNSView(_ view: NSViewType, context: Context) {
        context.coordinator.mountOwner?.mount(in: view)
        context.coordinator.mountOwner?.update(
            entries: entries,
            latestUserMessageID: latestUserMessageID,
            configuration: configuration,
            actions: actions
        )
    }

    static func dismantleNSView(_ view: NSViewType, coordinator: Coordinator) {
        coordinator.mountOwner?.unmount(from: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate let mountOwner: PersistentTranscriptListOwner?
        private var content: [TranscriptEntry] = []
        private var latestUserMessageID: UUID?
        private var configuration: TranscriptListConfiguration?
        private var actions = TranscriptListActions()
        // Mounted rows can outlive a surface's action closures. Resolve actions
        // at invocation time, including action-only updates and suspension.
        private lazy var forwardingActions = TranscriptListActions(
            hostName: { [weak self] in self?.actions.hostName($0) },
            navigateChat: { [weak self] in self?.actions.navigateChat($0) },
            editUserMessage: { [weak self] in self?.actions.editUserMessage($0, $1) },
            forkAssistantMessage: { [weak self] in self?.actions.forkAssistantMessage($0) },
            resolvePlan: { [weak self] in self?.actions.resolvePlan($0, $1) },
            implementPlan: { [weak self] in self?.actions.implementPlan($0) },
            canDeliverCommand: { [weak self] in self?.actions.canDeliverCommand() ?? false },
            deliverCommand: { [weak self] in self?.actions.deliverCommand($0, $1) }
        )
        private weak var presentation: TranscriptPresentationState?
        private weak var listView: NativeListView?
        let markdownCache = TranscriptMarkdownCache(limit: 48)
        let sizingPool = TranscriptRowSizingPool(limit: 12)
        private var invalidations: Set<UUID> = []
        private var invalidationScheduled = false
        private var invalidationMayFollow = false
        private var autoCollapseCheckScheduled = false
        private var widthRefreshScheduled = false
        private var displayedWidth: CGFloat?

        init(mountOwner: PersistentTranscriptListOwner? = nil) {
            self.mountOwner = mountOwner
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeListView() -> NativeListView {
            let view = NativeListView()
            listView = view
            view.estimatedRowHeight = 96
            view.topInset = Metrics.Space.xl
            view.bottomInset = Metrics.Space.xl
            view.rowAnimator = nil
            view.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportDidChange),
                name: NSView.boundsDidChangeNotification,
                object: view
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportDidChange),
                name: NSView.frameDidChangeNotification,
                object: view
            )
            view.rows {
                ListRow(TranscriptEmptyRow.self)
                    .when { $0.kind == .empty }
                    .estimatedHeight(96)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 96
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptUserRow.self)
                    .when { $0.kind == .user }
                    .estimatedHeight(96)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 96
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptAssistantRow.self)
                    .when { $0.kind == .assistant }
                    .estimatedHeight(96)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 96
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptToolRow.self)
                    .when { $0.kind == .tool }
                    .estimatedHeight(48)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 48
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptWorkRow.self)
                    .when { $0.kind == .work }
                    .estimatedHeight(72)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 72
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptCommandRow.self)
                    .when { $0.kind == .command }
                    .estimatedHeight(160)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 160
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptPlanRow.self)
                    .when { $0.kind == .plan }
                    .estimatedHeight(180)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 180
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptCompactionRow.self)
                    .when { $0.kind == .compaction }
                    .estimatedHeight(32)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 32
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptCompactionActivityRow.self)
                    .when { $0.kind == .compactionActivity }
                    .estimatedHeight(48)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 48
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptFailureRow.self)
                    .when { $0.kind == .failure }
                    .estimatedHeight(48)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 48
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(row, entry: entry, width: context.width, measurement: false)
                    }
                ListRow(TranscriptInterruptedRow.self)
                    .when { $0.kind == .interrupted }
                    .estimatedHeight(96)
                    .height { [weak self] entry, context in
                        self?.height(for: entry, width: context.width) ?? 96
                    }
                    .configure { [weak self] row, entry, context in
                        self?.configure(
                            row,
                            entry: entry,
                            width: context.width,
                            measurement: false
                        )
                    }
            }
            return view
        }

        func update(
            listView: NativeListView,
            entries: [TranscriptEntry],
            latestUserMessageID: UUID?,
            configuration: TranscriptListConfiguration,
            actions: TranscriptListActions,
            presentation: TranscriptPresentationState
        ) {
            applyUpdate(
                listView: listView,
                entries: entries,
                latestUserMessageID: latestUserMessageID,
                configuration: configuration,
                actions: actions,
                presentation: presentation
            )
        }

        /// Cached transcripts keep their data and measurements while detached,
        /// but surface-owned actions must not retain a window or conversation.
        func suspend() {
            actions = .init()
        }

        private func applyUpdate(
            listView: NativeListView,
            entries: [TranscriptEntry],
            latestUserMessageID: UUID?,
            configuration: TranscriptListConfiguration,
            actions: TranscriptListActions,
            presentation: TranscriptPresentationState
        ) {
            let oldConfiguration = self.configuration
            self.configuration = configuration
            self.actions = actions
            self.presentation = presentation
            guard
                content != entries || self.latestUserMessageID != latestUserMessageID
                    || oldConfiguration != configuration
            else { return }

            let requiresReload = oldConfiguration?.hasSameLayout(as: configuration) != true
            if !requiresReload, oldConfiguration != configuration {
                for case let row as TranscriptNativeRow in listView.visibleRowViews {
                    row.updateInteractionConfiguration(configuration)
                }
            }
            // Interaction metadata must not discard measurements or request a
            // bottom follow. Content arriving in the same update still applies
            // synchronously through the usual incremental update plan below.
            if !requiresReload, content == entries, self.latestUserMessageID == latestUserMessageID { return }

            let validPresentationIDs = entries.reduce(into: Set<UUID>()) {
                $0.formUnion($1.presentationIDs)
            }
            presentation.prune(validTimelineIDs: validPresentationIDs)
            let validEntryIDs = Set(entries.map(\.id))
            markdownCache.prune(validEntryIDs: validEntryIDs)
            sizingPool.prune(validEntryIDs: validEntryIDs)

            let first = content.isEmpty
            let userSent =
                self.latestUserMessageID != latestUserMessageID
                && latestUserMessageID != nil
            let follow =
                first || userSent
                || (listView.isScrolledToBottom(tolerance: Metrics.Space.l)
                    && !listView.isUserInteractingWithScroll)

            if requiresReload {
                sizingPool.removeAll()
                listView.reloadData()
            }
            prepareWorkCompletionTransitions(
                from: content,
                to: entries,
                in: listView,
                presentation: presentation
            )
            let plan = TranscriptListUpdatePlan.make(old: content, new: entries)
            if plan.replacesAll {
                if !content.isEmpty { sizingPool.removeAll() }
                listView.apply(entries)
            } else {
                for entry in plan.updates {
                    sizingPool.invalidate(entry.id)
                    listView.update(entry)
                }
                if !plan.appends.isEmpty { listView.append(contentsOf: plan.appends) }
            }
            content = entries
            self.latestUserMessageID = latestUserMessageID
            followBottom(listView, if: follow)
            schedulePendingAutoCollapseCheck()
        }

        /// A successful run is allowed to adopt its collapsed default only
        /// after the row is wholly outside the reader's viewport. Partial
        /// visibility is still visibility: collapsing then would remove words
        /// from under the reader and change the height they are looking at.
        private func prepareWorkCompletionTransitions(
            from old: [TranscriptEntry],
            to new: [TranscriptEntry],
            in view: NativeListView,
            presentation: TranscriptPresentationState
        ) {
            presentation.disclosures.prepareWorkCompletionTransitions(
                from: old, to: new,
                visibleIDs: Set(old.filter { rowIntersectsViewport($0.id, in: view) }.map(\.id))
            )
        }

        @objc private func viewportDidChange() {
            scheduleWidthRefresh()
            schedulePendingAutoCollapseCheck()
        }

        private func scheduleWidthRefresh() {
            guard let view = listView, view.bounds.width > 0,
                view.bounds.width != displayedWidth, !widthRefreshScheduled
            else { return }
            widthRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                widthRefreshScheduled = false
                guard let view = listView, view.bounds.width > 0,
                    view.bounds.width != displayedWidth
                else { return }
                displayedWidth = view.bounds.width
                // ListViewKit remeasures heights on resize, but mounted rows
                // keep their configuration. Refresh those rows without replacing
                // the list or treating the resize as new conversation content.
                for entry in content where view.rowView(for: entry.id) != nil {
                    refreshDisplayedRow(entry.id, in: view)
                }
                view.layoutSubtreeIfNeeded()
            }
        }

        private func schedulePendingAutoCollapseCheck() {
            guard !autoCollapseCheckScheduled else { return }
            autoCollapseCheckScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                autoCollapseCheckScheduled = false
                collapsePendingWorkOutsideViewport()
            }
        }

        private func collapsePendingWorkOutsideViewport() {
            guard let view = listView, let presentation else { return }
            var collapsed: [UUID] = []
            for entry in content where presentation.disclosures.hasPendingAutoCollapse(entry.id) {
                guard !rowIntersectsViewport(entry.id, in: view),
                    presentation.disclosures.completeAutoCollapse(entry.id)
                else { continue }
                collapsed.append(entry.id)
            }
            guard !collapsed.isEmpty else { return }
            for id in collapsed { refreshDisplayedRow(id, in: view) }
            view.layoutSubtreeIfNeeded()
        }

        private func rowIntersectsViewport(_ id: UUID, in view: NativeListView) -> Bool {
            let row = view.rectForRow(with: id)
            guard !row.isEmpty, view.bounds.width > 0, view.bounds.height > 0 else {
                return false
            }
            let viewport = CGRect(origin: view.contentOffset, size: view.bounds.size)
            return row.intersects(viewport)
        }

        private func height(for entry: TranscriptEntry, width: CGFloat) -> CGFloat {
            guard let configuration, let presentation else { return 96 }
            return sizingPool.height(
                for: entry,
                width: width,
                configuration: configuration,
                presentation: presentation
            ) { [weak self] row in
                self?.configure(row, entry: entry, width: width, measurement: true)
            }
        }

        private func configure(
            _ row: TranscriptNativeRow,
            entry: TranscriptEntry,
            width: CGFloat,
            measurement: Bool
        ) {
            guard let configuration, let presentation else { return }
            row.configure(
                entry: entry,
                proposedWidth: width,
                configuration: configuration,
                actions: measurement ? .init() : forwardingActions,
                presentation: presentation,
                markdownCache: markdownCache,
                measurement: measurement
            ) { [weak self] id, mayFollow in
                self?.sizingPool.invalidate(id)
                self?.invalidate(id, mayFollow: mayFollow)
            }
        }

        private func invalidate(_ id: UUID, mayFollow: Bool) {
            invalidations.insert(id)
            invalidationMayFollow = invalidationMayFollow || mayFollow
            guard !invalidationScheduled else { return }
            invalidationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                invalidationScheduled = false
                let ids = invalidations
                invalidations.removeAll()
                let view = listView
                let follow =
                    invalidationMayFollow
                    && view?.isScrolledToBottom(tolerance: Metrics.Space.l) == true
                    && view?.isUserInteractingWithScroll == false
                invalidationMayFollow = false
                guard let view else { return }
                for id in ids { refreshDisplayedRow(id, in: view) }
                view.layoutSubtreeIfNeeded()
                followBottom(view, if: follow)
            }
        }

        func refreshDisplayedRow(_ id: UUID, in view: NativeListView) {
            sizingPool.invalidate(id)
            if let index = content.firstIndex(where: { $0.id == id }),
                let row = view.rowView(for: id) as? TranscriptNativeRow
            {
                configure(
                    row,
                    entry: content[index],
                    width: view.bounds.width,
                    measurement: false
                )
            }
            view.invalidateLayout(forRowWith: id)
        }

        private func followBottom(_ view: NativeListView, if shouldFollow: Bool) {
            guard shouldFollow, !view.isUserInteractingWithScroll else { return }
            view.layoutSubtreeIfNeeded()
            guard !view.isUserInteractingWithScroll else { return }
            view.scrollToBottom(animated: false)
        }
    }
}
