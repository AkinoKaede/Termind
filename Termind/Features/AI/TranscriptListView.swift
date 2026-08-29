import AppKit
import ListViewKit
import Observation
import SwiftUI

nonisolated struct TranscriptEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case empty
        case user
        case assistant
        case tool
        case work
        case command
        case plan
        case compaction
        case compactionActivity
        case interrupted
    }

    nonisolated enum Content: Hashable, Sendable {
        case empty
        case user(ChatMessage, canEdit: Bool)
        case assistant(ChatMessage, canFork: Bool)
        case tool(AgentToolCard)
        case work(AgentWorkGroup)
        case command(SuggestedCommand)
        case plan(AgentPlanCard)
        case compaction(AgentCompactionMark)
        case compactionActivity(AgentCompactionActivity)
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

    static func items(
        timeline: [TimelineItem],
        isInterrupted: Bool,
        canEdit: (UUID) -> Bool,
        canFork: (UUID) -> Bool
    ) -> [Self] {
        if timeline.isEmpty { return [.init(id: emptyID, content: .empty)] }
        var result = timeline.enumerated().map { index, item in
            let content: Content =
                switch item {
                case .message(let message) where message.role == .user:
                    .user(message, canEdit: canEdit(message.id))
                case .message(let message):
                    .assistant(message, canFork: canFork(message.id))
                case .tool(let card): .tool(card)
                case .work(let group): .work(group)
                case .command(let command): .command(command)
                case .plan(let card): .plan(card)
                case .compaction(let mark): .compaction(mark)
                case .compactionActivity(let activity): .compactionActivity(activity)
                }
            return Self(id: item.id, content: content, hasLeadingSpacing: index > 0)
        }
        if isInterrupted {
            result.append(.init(id: interruptedID, content: .interrupted, hasLeadingSpacing: true))
        }
        return result
    }

    var presentationIDs: Set<UUID> {
        var result: Set<UUID> = [id]
        guard case .work(let group) = content else { return result }
        for item in group.items {
            result.insert(item.id)
            if case .tools(let batch) = item { result.formUnion(batch.cards.map(\.id)) }
        }
        return result
    }

    var kind: Kind {
        switch content {
        case .empty: .empty
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        case .work: .work
        case .command: .command
        case .plan: .plan
        case .compaction: .compaction
        case .compactionActivity: .compactionActivity
        case .interrupted: .interrupted
        }
    }

    var isActivelyStreaming: Bool {
        switch content {
        case .assistant(let message, _): message.isStreaming
        case .work(let group): !group.run.state.isTerminal
        case .compactionActivity(let activity):
            if case .running = activity.state { true } else { false }
        default: false
        }
    }
}

@MainActor
@Observable
final class TranscriptPresentationState {
    static let reasoningTitleDuration: TimeInterval = 3

    private struct DisclosureState {
        var isExpanded: Bool
        var readerDidToggle: Bool
        var revision: UInt64
    }
    private struct ReasoningTitleState {
        var revision: String
        var expiresAt: Date
    }
    private struct MessageEditState {
        var isEditing = false
        var text = ""
        var bubbleWidth: CGFloat = 0
        var revision: UInt64 = 0
    }

    private var disclosureStates: [UUID: DisclosureState] = [:]
    private var pendingAutoCollapseIDs: Set<UUID> = []
    private var reasoningTitles: [UUID: ReasoningTitleState] = [:]
    private var messageEdits: [UUID: MessageEditState] = [:]
    private var nextRevision: UInt64 = 1

    func isExpanded(_ id: UUID, default value: Bool = false) -> Bool {
        disclosureStates[id]?.isExpanded ?? value
    }
    func readerDidToggle(_ id: UUID) -> Bool { disclosureStates[id]?.readerDidToggle == true }
    func toggleDisclosure(_ id: UUID, default value: Bool = false) {
        pendingAutoCollapseIDs.remove(id)
        disclosureStates[id] = .init(
            isExpanded: !(disclosureStates[id]?.isExpanded ?? value),
            readerDidToggle: true,
            revision: takeRevision()
        )
    }
    func followDefault(_ expanded: Bool, for id: UUID) {
        guard disclosureStates[id]?.readerDidToggle != true else { return }
        pendingAutoCollapseIDs.remove(id)
        disclosureStates[id] = .init(
            isExpanded: expanded, readerDidToggle: false, revision: takeRevision()
        )
    }
    func deferAutoCollapse(_ id: UUID) {
        guard disclosureStates[id]?.readerDidToggle != true else { return }
        pendingAutoCollapseIDs.insert(id)
        disclosureStates[id] = .init(
            isExpanded: true, readerDidToggle: false, revision: takeRevision()
        )
    }
    func hasPendingAutoCollapse(_ id: UUID) -> Bool {
        pendingAutoCollapseIDs.contains(id)
    }
    @discardableResult
    func completeAutoCollapse(_ id: UUID) -> Bool {
        guard pendingAutoCollapseIDs.remove(id) != nil,
            disclosureStates[id]?.readerDidToggle != true
        else { return false }
        disclosureStates[id] = .init(
            isExpanded: false, readerDidToggle: false, revision: takeRevision()
        )
        return true
    }

    /// Returns an absolute deadline so remounting or measuring a row cannot
    /// restart its transient reasoning title. A changed Markdown revision does
    /// deliberately receive a fresh three-second window.
    func reasoningTitleDeadline(
        for id: UUID,
        revision: String,
        now: Date = .now
    ) -> Date {
        if let state = reasoningTitles[id], state.revision == revision {
            return state.expiresAt
        }
        let deadline = now.addingTimeInterval(Self.reasoningTitleDuration)
        reasoningTitles[id] = .init(revision: revision, expiresAt: deadline)
        return deadline
    }
    func prune(validTimelineIDs: Set<UUID>) {
        let staleDisclosures = disclosureStates.keys.filter { !validTimelineIDs.contains($0) }
        let staleReasoningTitles = reasoningTitles.keys.filter { !validTimelineIDs.contains($0) }
        let staleEdits = messageEdits.keys.filter { !validTimelineIDs.contains($0) }
        guard !staleDisclosures.isEmpty || !staleReasoningTitles.isEmpty || !staleEdits.isEmpty
        else { return }
        for id in staleDisclosures { disclosureStates[id] = nil }
        pendingAutoCollapseIDs.formIntersection(validTimelineIDs)
        for id in staleReasoningTitles { reasoningTitles[id] = nil }
        for id in staleEdits { messageEdits[id] = nil }
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
    func messageEditBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.messageEditText(id) ?? "" },
            set: { [weak self] in self?.setMessageEditText($0, for: id) }
        )
    }
    func layoutRevision(for ids: Set<UUID>) -> UInt64 {
        ids.reduce(0) { result, id in
            result &+ (disclosureStates[id]?.revision ?? 0) &+ (messageEdits[id]?.revision ?? 0)
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
    let locale: Locale
    let reduceMotion: Bool
    let colorScheme: ColorScheme
    var horizontalInset: CGFloat { isCompact ? Metrics.Space.l : Metrics.Space.xl }
}

@MainActor
struct TranscriptListActions {
    var hostName: (UUID) -> String? = { _ in nil }
    var editUserMessage: (UUID, String) -> Void = { _, _ in }
    var forkAssistantMessage: (UUID) -> Void = { _ in }
    var resolvePlan: (UUID, AgentPlan.Outcome) -> Void = { _, _ in }
    var implementPlan: (AgentPlanCard) -> Void = { _ in }
    var canDeliverCommand: () -> Bool = { false }
    var deliverCommand: (String, Bool) -> Void = { _, _ in }
}

struct TranscriptListView: NSViewRepresentable {
    typealias NSViewType = ListView<TranscriptEntry>
    let entries: [TranscriptEntry]
    let latestUserMessageID: UUID?
    let configuration: TranscriptListConfiguration
    let actions: TranscriptListActions
    let presentation: TranscriptPresentationState

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ view: NSViewType, context: Context) {
        context.coordinator.update(
            listView: view,
            entries: entries,
            latestUserMessageID: latestUserMessageID,
            configuration: configuration,
            actions: actions,
            presentation: presentation
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        private var content: [TranscriptEntry] = []
        private var latestUserMessageID: UUID?
        private var configuration: TranscriptListConfiguration?
        private var actions = TranscriptListActions()
        private weak var presentation: TranscriptPresentationState?
        private weak var listView: NSViewType?
        let markdownCache = TranscriptMarkdownCache(limit: 48)
        let sizingPool = TranscriptRowSizingPool(limit: 12)
        private var invalidations: Set<UUID> = []
        private var invalidationScheduled = false
        private var invalidationMayFollow = false
        private var autoCollapseCheckScheduled = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeListView() -> NSViewType {
            let view = NSViewType()
            listView = view
            view.estimatedRowHeight = 96
            view.topInset = Metrics.Space.xl
            view.bottomInset = Metrics.Space.xl
            view.rowAnimator = nil
            view.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportDidChange),
                name: NSView.boundsDidChangeNotification,
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
            listView: NSViewType,
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

        private func applyUpdate(
            listView: NSViewType,
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

            if oldConfiguration != configuration {
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
            in view: NSViewType,
            presentation: TranscriptPresentationState
        ) {
            let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            for entry in new {
                guard case .work(let group) = entry.content,
                    group.run.state == .completed,
                    !group.appearsAfterAnswer,
                    case .work(let oldGroup)? = previous[entry.id]?.content,
                    oldGroup.run.state != .completed,
                    !presentation.readerDidToggle(entry.id)
                else { continue }

                if rowIntersectsViewport(entry.id, in: view) {
                    presentation.deferAutoCollapse(entry.id)
                } else {
                    presentation.followDefault(false, for: entry.id)
                }
            }
        }

        @objc private func viewportDidChange() {
            schedulePendingAutoCollapseCheck()
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
            for entry in content where presentation.hasPendingAutoCollapse(entry.id) {
                guard !rowIntersectsViewport(entry.id, in: view),
                    presentation.completeAutoCollapse(entry.id)
                else { continue }
                collapsed.append(entry.id)
            }
            guard !collapsed.isEmpty else { return }
            for id in collapsed { refreshDisplayedRow(id, in: view) }
            view.layoutSubtreeIfNeeded()
        }

        private func rowIntersectsViewport(_ id: UUID, in view: NSViewType) -> Bool {
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
                actions: measurement ? .init() : actions,
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

        func refreshDisplayedRow(_ id: UUID, in view: NSViewType) {
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

        private func followBottom(_ view: NSViewType, if shouldFollow: Bool) {
            guard shouldFollow, !view.isUserInteractingWithScroll else { return }
            view.layoutSubtreeIfNeeded()
            guard !view.isUserInteractingWithScroll else { return }
            view.scrollToBottom(animated: false)
        }
    }
}
