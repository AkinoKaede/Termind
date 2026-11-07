// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

/// Rebuilds presentation boundaries from visible history, including messages
/// compacted out of the model transcript. No UI-only ordering needs persistence.
nonisolated struct AgentWorkSegmentation {
    struct Segment {
        var id: UUID
        var runID: UUID
        var boundaryMessageID: UUID?
        var lowerBound: Int
        var upperBound: Int
        var startedAt: Date?
        var finishedAt: Date?
    }

    let messages: [ChatMessage]
    let positions: [UUID: Int]
    let messageRunIDs: [UUID: UUID]
    private(set) var segments: [UUID: Segment] = [:]
    private(set) var messageSegments: [UUID: UUID] = [:]
    private var segmentsByRun: [UUID: [UUID]] = [:]
    private var sourcesByCall: [UUID: [String: UUID]] = [:]
    private var lastPositionsByRun: [UUID: Int] = [:]
    private var toolResultPositions: [UUID: Int] = [:]
    private var timestampAnchors: [(date: Date, position: Int)] = []

    init(
        messages: [ChatMessage], transcript: [AgentTranscriptMessage],
        messageRunIDs: [UUID: UUID], runs: [UUID: AgentRunSummary], toolCards: [AgentToolCard]
    ) {
        self.messages = messages
        self.messageRunIDs = messageRunIDs
        positions = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
        for (position, message) in messages.enumerated()
        where timestampAnchors.last.map({ message.createdAt > $0.date }) ?? true {
            timestampAnchors.append((message.createdAt, position))
        }
        let positionsByRun = Dictionary(
            grouping: messages.indices.filter { messageRunIDs[messages[$0].id] != nil },
            by: { messageRunIDs[messages[$0].id]! }
        )
        let runIDs = Set(runs.keys).union(positionsByRun.keys).union(toolCards.map(\.invocation.runID))
        var nextUserPositions = Array(repeating: messages.count, count: messages.count)
        var nextUser = messages.count
        for index in messages.indices.reversed() {
            nextUserPositions[index] = nextUser
            if messages[index].role == .user { nextUser = index }
        }
        for runID in runIDs {
            let owned = positionsByRun[runID] ?? []
            lastPositionsByRun[runID] = owned.last
            let boundaries = owned.filter { messages[$0].role == .user }
            var current = Segment(
                id: runID, runID: runID,
                lowerBound: owned.first ?? 0, upperBound: messages.count,
                startedAt: runs[runID]?.startedAt ?? owned.first.map { messages[$0].createdAt }
            )
            var ids: [UUID] = []
            for index in boundaries {
                let message = messages[index]
                if index != owned.first {
                    let boundaryDate = max(current.startedAt ?? message.createdAt, message.createdAt)
                    current.upperBound = index
                    current.finishedAt = boundaryDate
                    segments[current.id] = current
                    ids.append(current.id)
                    current = Segment(
                        id: AgentTranscriptMessage.toolResultID(
                            runID: runID, callID: "__termind_work_segment__:\(message.id)"
                        ),
                        runID: runID, lowerBound: index + 1, upperBound: messages.count,
                        startedAt: boundaryDate
                    )
                }
                current.boundaryMessageID = message.id
                current.lowerBound = index + 1
            }
            if let last = owned.last { current.upperBound = nextUserPositions[last] }
            segments[current.id] = current
            ids.append(current.id)
            segmentsByRun[runID] = ids
            var segmentIndex = 0
            for index in owned {
                while segmentIndex + 1 < ids.count,
                    index >= segments[ids[segmentIndex]]!.upperBound
                {
                    segmentIndex += 1
                }
                messageSegments[messages[index].id] = ids[segmentIndex]
            }
        }
        for message in transcript where message.role == .assistant {
            guard let runID = messageRunIDs[message.id] else { continue }
            for call in message.toolCalls { sourcesByCall[runID, default: [:]][call.id] = message.id }
        }
        for card in toolCards {
            guard let position = sourcePosition(for: card.invocation) else { continue }
            let resultID = AgentTranscriptMessage.toolResultID(
                runID: card.invocation.runID, callID: card.invocation.call.id
            )
            toolResultPositions[resultID] = position + 1
        }
    }

    func sourcePosition(for invocation: AgentToolInvocation) -> Int? {
        if let source = invocation.sourceMessageID,
            messageRunIDs[source] == invocation.runID, let position = positions[source]
        {
            return position
        }
        guard let source = sourcesByCall[invocation.runID]?[invocation.call.id] else { return nil }
        return positions[source]
    }

    func segmentID(for invocation: AgentToolInvocation) -> UUID {
        if let index = sourcePosition(for: invocation), let id = messageSegments[messages[index].id] {
            return id
        }
        // Legacy invocations may have neither source identity nor call grammar.
        // Keep that uncertainty local; known ownership never depends on clocks.
        let ids = segmentsByRun[invocation.runID] ?? []
        return ids.last(where: { id in
            guard let segment = segments[id], segment.boundaryMessageID != nil,
                let date = segment.startedAt
            else { return false }
            return date <= invocation.createdAt
        }) ?? ids.first ?? invocation.runID
    }

    func timestampPosition(_ date: Date, afterEqual: Bool = false) -> Int {
        // Prefix maxima keep the first qualifying source position even when
        // clocks move backwards, without rescanning history for each legacy card.
        var lower = 0
        var upper = timestampAnchors.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let precedes = afterEqual ? timestampAnchors[middle].date <= date : timestampAnchors[middle].date < date
            if precedes {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < timestampAnchors.count ? timestampAnchors[lower].position : messages.count
    }

    func position(after messageID: UUID) -> Int? {
        positions[messageID].map { $0 + 1 } ?? toolResultPositions[messageID]
    }

    func clampedPosition(_ position: Int, in segment: Segment) -> Int {
        min(segment.upperBound, max(segment.lowerBound, position))
    }

    func endPosition(for runID: UUID, fallback date: Date) -> Int {
        lastPositionsByRun[runID].map { $0 + 1 } ?? timestampPosition(date)
    }
}
