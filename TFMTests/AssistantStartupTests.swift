// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import Testing

@testable import Termind

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AssistantStartupTests {
    @Test func windowsShareOneHistoryLoadEvenIfTheFirstWindowCloses() async throws {
        let history = StartupHistoryRepository()
        let app = makeApp(history: history)
        let first = WindowModel()
        let second = WindowModel()
        app.registerWindow(first)
        app.registerWindow(second)
        let restoration = Task { try await app.restoreAssistantConversations() }
        await history.waitForLoad()
        first.closeForWindow()
        app.unregisterWindow(first)

        let stored = StoredAgentConversation(
            id: UUID(), messages: [AgentTranscriptMessage(role: .user, text: "Saved history")],
            lastRunState: .completed)
        await history.finish(with: [stored])
        try await restoration.value
        #expect(second.assistantLibrary.conversations.map(\.id) == [stored.id])
        let third = WindowModel()
        app.registerWindow(third)
        try await app.restoreAssistantConversations()
        #expect(third.assistantLibrary.conversations.first === second.assistantLibrary.conversations.first)
        #expect(await history.loadCount == 1)
    }

    @Test func failedHistoryLoadCanBeRetried() async throws {
        let history = StartupHistoryRepository()
        let app = makeApp(history: history)
        let first = Task { try await app.restoreAssistantConversations() }
        await history.waitForLoad()
        await history.fail()
        await #expect(throws: CocoaError.self) { try await first.value }

        let second = Task { try await app.restoreAssistantConversations() }
        await history.waitForLoad()
        await history.finish(with: [])
        try await second.value
        try await app.restoreAssistantConversations()
        #expect(await history.loadCount == 2)
    }

    @Test func terminationDoesNotRestoreHistoryAfterTheLoadCompletes() async throws {
        let history = StartupHistoryRepository()
        let app = makeApp(history: history)
        let window = WindowModel()
        app.registerWindow(window)
        let restoration = Task { try await app.restoreAssistantConversations() }
        await history.waitForLoad()
        let shutdown = app.shutdownForTermination()
        await history.finish(with: [
            StoredAgentConversation(
                id: UUID(), messages: [AgentTranscriptMessage(role: .user, text: "Saved history")],
                lastRunState: .completed)
        ])
        await #expect(throws: CancellationError.self) { try await restoration.value }
        await shutdown.value
        #expect(window.assistantLibrary.conversations.isEmpty)
    }

    private func makeApp(history: StartupHistoryRepository) -> AppModel {
        AppModel(
            hosts: HostLibraryModel(),
            dependencies: AppDependencies(
                hostRepository: InMemoryHostRepository(snapshot: HostLibrarySnapshot(hosts: [], groups: [])),
                outboxRunner: nil,
                agentRunRepository: history,
                settingsDefaults: UserDefaults(suiteName: "termind.startup.tests.\(UUID().uuidString)")!))
    }
}

private actor StartupHistoryRepository: AgentRunPersisting {
    private(set) var loadCount = 0
    private var pending: CheckedContinuation<[StoredAgentConversation], any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func loadConversations() async throws -> [StoredAgentConversation] {
        loadCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForLoad() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(with conversations: [StoredAgentConversation]) {
        pending?.resume(returning: conversations)
        pending = nil
    }

    func fail() {
        pending?.resume(throwing: CocoaError(.fileReadCorruptFile))
        pending = nil
    }

    func save(_ snapshot: AgentRunSnapshot) {}
    func record(_ event: AgentEvent, runID: UUID) {}
    func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) {}
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) {}
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) {}
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID, replacingWith message: AgentTranscriptMessage
    ) {}
    func createConversation(_ conversation: StoredAgentConversation) {}
}
