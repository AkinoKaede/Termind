import Foundation
import Observation
import TermindApplication

nonisolated public enum AssistantTranscriptDisclosureID: Hashable, Sendable {
    case work(UUID)
    case tool(UUID)
    case toolDetail(UUID)
    case toolBatch(UUID)
    case reasoning(UUID)
    case plan(UUID)
    case compactionActivity(UUID)
    case failure(UUID)

    fileprivate var sourceID: UUID {
        switch self {
        case .work(let id), .tool(let id), .toolDetail(let id), .toolBatch(let id), .reasoning(let id), .plan(let id),
            .compactionActivity(let id), .failure(let id):
            id
        }
    }
}

@MainActor
@Observable
public final class AssistantTranscriptPresentationState {
    public static let reasoningTitleDuration: TimeInterval = 3

    private struct DisclosureState {
        var isExpanded: Bool
        var readerDidToggle: Bool
        var revision: UInt64
    }
    private struct ReasoningTitleState {
        var revision: String
        var expiresAt: Date
    }
    private var disclosureStates: [AssistantTranscriptDisclosureID: DisclosureState] = [:]
    private var pendingAutoCollapseIDs: Set<AssistantTranscriptDisclosureID> = []
    private var reasoningTitles: [UUID: ReasoningTitleState] = [:]
    private var nextRevision: UInt64 = 1

    public init() {}

    public func isExpanded(_ id: AssistantTranscriptDisclosureID, default value: Bool = false) -> Bool {
        disclosureStates[id]?.isExpanded ?? value
    }
    public func readerDidToggle(_ id: AssistantTranscriptDisclosureID) -> Bool {
        disclosureStates[id]?.readerDidToggle == true
    }
    public func toggleDisclosure(_ id: AssistantTranscriptDisclosureID, default value: Bool = false) {
        pendingAutoCollapseIDs.remove(id)
        disclosureStates[id] = .init(
            isExpanded: !(disclosureStates[id]?.isExpanded ?? value),
            readerDidToggle: true,
            revision: takeRevision()
        )
    }
    public func followDefault(_ expanded: Bool, for id: AssistantTranscriptDisclosureID) {
        guard disclosureStates[id]?.readerDidToggle != true else { return }
        pendingAutoCollapseIDs.remove(id)
        disclosureStates[id] = .init(
            isExpanded: expanded, readerDidToggle: false, revision: takeRevision()
        )
    }
    public func deferAutoCollapse(_ workID: UUID) {
        let id = AssistantTranscriptDisclosureID.work(workID)
        guard disclosureStates[id]?.readerDidToggle != true else { return }
        pendingAutoCollapseIDs.insert(id)
        disclosureStates[id] = .init(
            isExpanded: true, readerDidToggle: false, revision: takeRevision()
        )
    }
    public func hasPendingAutoCollapse(_ workID: UUID) -> Bool {
        pendingAutoCollapseIDs.contains(.work(workID))
    }
    @discardableResult
    public func completeAutoCollapse(_ workID: UUID) -> Bool {
        let id = AssistantTranscriptDisclosureID.work(workID)
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
    public func reasoningTitleDeadline(
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
    /// Called before list updates, while the previous geometry is still available.
    public func prepareWorkCompletionTransitions(
        from old: [AssistantTranscriptEntry], to new: [AssistantTranscriptEntry], visibleIDs: Set<UUID>
    ) {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        for entry in new {
            guard case .work(let group) = entry.content,
                group.run.state == .completed, !group.appearsAfterAnswer,
                case .work(let oldGroup)? = previous[entry.id]?.content,
                oldGroup.run.state != .completed, !readerDidToggle(.work(entry.id))
            else { continue }
            if visibleIDs.contains(entry.id) {
                deferAutoCollapse(entry.id)
            } else {
                followDefault(false, for: .work(entry.id))
            }
        }
    }

    @discardableResult
    public func collapseWorkOutsideViewport(visibleIDs: Set<UUID>) -> Set<UUID> {
        let candidates = pendingAutoCollapseIDs.filter { !visibleIDs.contains($0.sourceID) }
        return Set(candidates.compactMap { completeAutoCollapse($0.sourceID) ? $0.sourceID : nil })
    }

    public func prune(validTimelineIDs: Set<UUID>) {
        for id in disclosureStates.keys where !validTimelineIDs.contains(id.sourceID) { disclosureStates[id] = nil }
        pendingAutoCollapseIDs = Set(pendingAutoCollapseIDs.filter { validTimelineIDs.contains($0.sourceID) })
        for id in reasoningTitles.keys where !validTimelineIDs.contains(id) { reasoningTitles[id] = nil }
    }

    public func layoutRevision(for ids: Set<UUID>) -> UInt64 {
        disclosureStates.reduce(0) { result, entry in
            ids.contains(entry.key.sourceID) ? result &+ entry.value.revision : result
        }
    }

    private func takeRevision() -> UInt64 {
        defer { nextRevision &+= 1 }
        return nextRevision
    }
}
