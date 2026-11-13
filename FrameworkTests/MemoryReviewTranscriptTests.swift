// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import Synchronization
import Testing

@testable import TermindApplication

@Suite @MainActor
struct MemoryReviewTranscriptTests {
    @Test func preparingMultipleWindowsSerializesEachMessageOnceOffMainThread() async throws {
        let messages = (0..<205).map { AgentTranscriptMessage(role: .user, text: "Request \($0)") }
        let calls = Mutex<[UUID: Int]>([:])
        let transcript = MemoryReviewTranscript(messages: messages) { message in
            #expect(!Thread.isMainThread)
            calls.withLock { $0[message.id, default: 0] += 1 }
            return AgentCompaction.serialized([message], toolResultLimit: 300)
        }
        var progress = MemoryLearningProgress()
        var batches: [MemoryReviewTranscript.Batch] = []
        while let batch = try await transcript.nextBatch(progress: progress) {
            batches.append(batch)
            progress.lastReviewedMessage = batch.lastMessageID
        }

        #expect(batches.map(\.lastMessageID) == [messages[99].id, messages[199].id, messages[204].id])
        #expect(batches.map(\.hasMore) == [true, true, false])
        #expect(batches[1].messages.map(\.id) == Array(messages[98..<200]).map(\.id))
        #expect(batches[2].messages.map(\.id) == Array(messages[198..<205]).map(\.id))
        let counts = calls.withLock { $0 }
        #expect(counts.count == messages.count)
        #expect(counts.values.allSatisfy { $0 == 1 })
    }

    @Test func characterBudgetIncludesSeparatorsAndTrimsEarlierContext() async throws {
        let messages = [
            AgentTranscriptMessage(role: .user, text: String(repeating: "a", count: 13_992)),
            AgentTranscriptMessage(role: .assistant, text: ""),
            AgentTranscriptMessage(role: .user, text: String(repeating: "b", count: 13_992)),
            AgentTranscriptMessage(role: .user, text: "Next"),
        ]
        let transcript = MemoryReviewTranscript(messages: messages)
        let first = try #require(try await transcript.nextBatch(progress: .init()))
        #expect(first.lastMessageID == messages[2].id)
        #expect(AgentCompaction.serialized(first.messages, toolResultLimit: 300).count == 27_999)

        let next = try #require(
            try await transcript.nextBatch(progress: .init(lastReviewedMessage: first.lastMessageID)))
        #expect(next.messages.map(\.id) == Array(messages[1...]).map(\.id))
        #expect(next.lastMessageID == messages[3].id)
        #expect(!next.hasMore)
    }

    @Test func carriageReturnBeforeSeparatorFitsExactCharacterBudget() async throws {
        let messages = [
            AgentTranscriptMessage(role: .user, text: String(repeating: "a", count: 13_992) + "\r"),
            AgentTranscriptMessage(role: .user, text: String(repeating: "b", count: 13_993)),
        ]
        let transcript = MemoryReviewTranscript(messages: messages)
        let batch = try #require(try await transcript.nextBatch(progress: .init()))
        #expect(batch.lastMessageID == messages[1].id)
        #expect(AgentCompaction.serialized(batch.messages, toolResultLimit: 300).count == 28_000)
        #expect(!batch.hasMore)
    }

    @Test func pendingActivityRewindsCursorWithoutConsumingLaterOrMissingMessages() async throws {
        let messages = (0..<105).map { AgentTranscriptMessage(role: .user, text: "Request \($0)") }
        let earlier = MemoryLearningEvent(id: UUID(), sourceMessageID: messages[2].id)
        let later = MemoryLearningEvent(id: UUID(), sourceMessageID: messages[104].id)
        let missing = MemoryLearningEvent(id: UUID(), sourceMessageID: UUID())
        let transcript = MemoryReviewTranscript(messages: messages)
        let first = try #require(
            try await transcript.nextBatch(
                progress: .init(lastReviewedMessage: messages[103].id, events: [earlier, later, missing])))
        #expect(first.lastMessageID == messages[101].id)
        #expect(first.messages.first?.id == messages[0].id)
        #expect(first.reviewedActivityIDs == [earlier.id])

        let next = try #require(
            try await transcript.nextBatch(
                progress: .init(lastReviewedMessage: first.lastMessageID, events: [later, missing])))
        #expect(next.messages.map(\.id) == Array(messages[100...]).map(\.id))
        #expect(next.reviewedActivityIDs == [later.id])
        #expect(!next.hasMore)
    }

    @Test func oversizedMessageMakesProgressWithoutEnteringTheNextWindowsContext() async throws {
        let messages = [
            AgentTranscriptMessage(role: .user, text: String(repeating: "文", count: 40_000)),
            AgentTranscriptMessage(role: .assistant, text: "Done"),
        ]
        let transcript = MemoryReviewTranscript(messages: messages)
        let first = try #require(try await transcript.nextBatch(progress: .init()))
        #expect(first.messages.map(\.id) == [messages[0].id])
        #expect(first.hasMore)
        let next = try #require(
            try await transcript.nextBatch(progress: .init(lastReviewedMessage: first.lastMessageID)))
        #expect(next.messages.map(\.id) == [messages[1].id])
        #expect(!next.hasMore)
    }

    @Test func mainActorCanCancelWhileTranscriptPreparationIsBusy() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let messages = (0..<100).map { AgentTranscriptMessage(role: .user, text: "Request \($0)") }
        let transcript = MemoryReviewTranscript(messages: messages) { message in
            #expect(!Thread.isMainThread)
            calls.withLock { $0 += 1 }
            entered.continuation.yield()
            #expect(release.wait(timeout: .now() + 5) == .success)
            return AgentCompaction.serialized([message], toolResultLimit: 300)
        }
        let preparation = Task { try await transcript.nextBatch(progress: .init()) }
        defer {
            release.signal()
            entered.continuation.finish()
        }
        for await _ in entered.stream { break }
        preparation.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await preparation.value }
        #expect(calls.withLock { $0 } == 1)
    }
}
