// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

/// Prepares review windows away from the UI actor, reusing each message's serialized size across windows.
actor MemoryReviewTranscript {
    nonisolated struct Batch: Sendable {
        let messages: [AgentTranscriptMessage]
        let lastMessageID: UUID
        let reviewedActivityIDs: [UUID]
        let hasMore: Bool
    }

    private nonisolated struct Size {
        var characters = 0
        var endsWithCarriageReturn = false

        mutating func append(_ other: Size) {
            guard other.characters > 0 else { return }
            if characters > 0 {
                // AgentCompaction joins nonempty message fragments with a newline. CRLF is one Character.
                characters += endsWithCarriageReturn ? 0 : 1
            }
            characters += other.characters
            endsWithCarriageReturn = other.endsWithCarriageReturn
        }
    }

    private let messages: [AgentTranscriptMessage]
    private let serialize: @Sendable (AgentTranscriptMessage) -> String
    private var positions: [UUID: Int]?
    private var sizes: [Int: Size] = [:]

    init(
        messages: [AgentTranscriptMessage],
        serialize: @escaping @Sendable (AgentTranscriptMessage) -> String = {
            AgentCompaction.serialized([$0], toolResultLimit: 300)
        }
    ) {
        self.messages = messages
        self.serialize = serialize
    }

    func nextBatch(progress: MemoryLearningProgress) throws -> Batch? {
        try Task.checkCancellation()
        if positions == nil {
            var indexed: [UUID: Int] = [:]
            for (index, message) in messages.enumerated() {
                try Task.checkCancellation()
                if indexed[message.id] == nil { indexed[message.id] = index }
            }
            positions = indexed
        }
        let cursorIndex = progress.lastReviewedMessage.flatMap { positions?[$0] }
        var pendingIndex = messages.count
        for event in progress.events {
            try Task.checkCancellation()
            if let index = positions?[event.sourceMessageID] { pendingIndex = min(pendingIndex, index) }
        }
        let start = min(cursorIndex.map { $0 + 1 } ?? 0, pendingIndex)
        guard start < messages.count else { return nil }

        var end = start
        var size = Size()
        while end < messages.count, end - start < 100 {
            var candidate = size
            candidate.append(try serializedSize(at: end))
            if candidate.characters > 28_000, end > start { break }
            size = candidate
            end += 1
        }

        var contextStart = start
        while contextStart > max(0, start - 2) {
            var candidate = try serializedSize(at: contextStart - 1)
            candidate.append(size)
            guard candidate.characters <= 28_000 else { break }
            size = candidate
            contextStart -= 1
        }
        let messageIDs = Set(messages[start..<end].map(\.id))
        var reviewedIDs: [UUID] = []
        for event in progress.events {
            try Task.checkCancellation()
            if messageIDs.contains(event.sourceMessageID) { reviewedIDs.append(event.id) }
        }
        try Task.checkCancellation()
        return Batch(
            messages: Array(messages[contextStart..<end]), lastMessageID: messages[end - 1].id,
            reviewedActivityIDs: reviewedIDs, hasMore: end < messages.count)
    }

    private func serializedSize(at index: Int) throws -> Size {
        try Task.checkCancellation()
        if let cached = sizes[index] { return cached }
        let text = serialize(messages[index])
        try Task.checkCancellation()
        let size = Size(characters: text.count, endsWithCarriageReturn: text.hasSuffix("\r"))
        sizes[index] = size
        return size
    }
}
