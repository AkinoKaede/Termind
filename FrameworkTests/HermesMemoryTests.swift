import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct HermesMemoryTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appending(path: "memory-test-\(UUID())") }

    @Test func disabledMemoryDoesNotCreateFiles() async throws {
        let url = directory()
        let model = MemoryModel(storage: GRDBMemoryStore(directory: url))
        await model.refresh()
        #expect(await model.session(UUID()) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func memoryAndSnapshotSurviveReopening() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        _ = try await store.applyMemory([.init(action: .add, target: .user, content: "Likes concise replies")])
        let id = UUID()
        let original = try await store.snapshot(for: id)
        _ = try await store.applyMemory([
            .init(action: .replace, target: .user, content: "Likes detailed replies", oldText: "concise")
        ])
        try await store.close()
        let reopened = GRDBMemoryStore(directory: url)
        #expect(try await reopened.snapshot(for: id) == original)
        #expect(try await reopened.snapshot(for: UUID()).contains("detailed"))
        try await reopened.close()
    }

    @Test func editingPreservesSeparateMemoryEntries() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let state = try await store.replaceTarget(.memory, text: "First fact\n§\nSecond fact")
        #expect(state.entries.count == 2)
        let updated = try await store.applyMemory([.init(action: .remove, target: .memory, oldText: "First")])
        #expect(updated.text(.memory) == "Second fact")
        try await store.close()
    }

    @Test func staleBackgroundReviewCannotOverwriteForegroundChanges() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let state = try await store.memoryState()
        _ = try await store.applyMemory([.init(action: .add, target: .user, content: "New preference")])
        let id = UUID()
        let messageID = UUID()
        let result = try await store.applyReview(
            [.init(action: .add, target: .user, content: "Old assumption")], expected: state,
            messageID: messageID, conversationID: id)
        #expect(result == nil)
        #expect(try await store.lastReviewedMessage(id) == nil)
        try await store.close()
    }

    @Test func searchSupportsChineseAndRemovesDeletedHistory() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let conversation = StoredAgentConversation(
            id: UUID(),
            messages: [
                .init(role: .user, text: "部署服务器需要测试"), .init(role: .assistant, text: "Done"),
            ], lastRunState: .completed)
        try await store.replaceHistory([conversation])
        #expect(try await store.searchSessions(.init(query: "服务器")).encodedString.contains("部署"))
        #expect(try await store.searchSessions(.init(query: "部署")).encodedString.contains("服务器"))
        #expect(
            try await store.searchSessions(.init(conversationID: conversation.id, offset: 1)).encodedString.contains(
                "Done"))
        try await store.replaceHistory([])
        #expect(try await !store.searchSessions(.init(query: "服务器")).encodedString.contains("部署"))
        try await store.close()
    }

    @Test func destroyRevokesActiveAccessAndReenableCanBackfillOldHistory() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let model = MemoryModel(storage: store)
        let history = InMemoryAgentRunRepository()
        let conversationID = UUID()
        await history.save(
            .init(
                conversationID: conversationID, state: .completed, permissionMode: .askForApproval,
                messages: [.init(role: .user, text: "Historical zebra fact")]))
        model.attachHistory(history)
        await model.setEnabled(true)
        let session = try #require(await model.session(conversationID))
        _ = try await session.access.applyMemory([.init(action: .add, target: .memory, content: "Temporary memory")])
        await model.destroy()
        #expect(!model.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: (any Error).self) {
            try await session.access.applyMemory([.init(action: .add, target: .memory, content: "Late write")])
        }
        #expect(session.context.transform(.init(systemPrompt: "Base", messages: [], tools: [])).systemPrompt == "Base")
        await model.destroy()
        await model.setEnabled(true)
        let fresh = try #require(await model.session(conversationID))
        #expect(try await fresh.access.memoryState().entries.isEmpty)
        #expect(try await fresh.access.searchSessions(.init(query: "zebra")).encodedString.contains("Historical"))
        await model.setEnabled(false)
    }

    @Test func suspendedMemoryDefersTerminalHistoryIndexUntilResume() async throws {
        let store = MemoryLifecycleStore()
        let model = MemoryModel(storage: store)
        let history = InMemoryAgentRunRepository()
        let repository = MemoryIndexedAgentRepository(base: history, memory: model)
        await model.setEnabled(true)
        try await waitUntil { await store.historyReplacementCount == 1 && !model.isIndexing }

        model.suspend()
        let conversationID = UUID()
        try await repository.save(
            .init(
                conversationID: conversationID, state: .completed, permissionMode: .askForApproval,
                messages: [.init(role: .user, text: "Saved after suspension")]))

        #expect(!model.isIndexing)
        #expect(await store.historyReplacementCount == 1)

        model.resume()
        try await waitUntil { await store.historyReplacementCount == 2 && !model.isIndexing }
        #expect(await store.lastHistory?.contains(where: { $0.id == conversationID }) == true)
    }

    @Test func suspendInvalidatesExistingMemoryAccessAcrossResume() async throws {
        let store = MemoryLifecycleStore()
        let model = MemoryModel(storage: store)
        await model.setEnabled(true)
        let conversationID = UUID()
        let original = try #require(await model.session(conversationID))

        model.suspend()
        #expect(await model.session(conversationID) == nil)
        model.resume()

        await #expect(throws: CancellationError.self) { try await original.access.memoryState() }
        let resumed = try #require(await model.session(conversationID))
        _ = try await resumed.access.memoryState()
    }

    @Test func suspendPreventsStaleReviewFromApplyingAfterResume() async throws {
        let store = MemoryLifecycleStore()
        let model = MemoryModel(storage: store)
        await model.setEnabled(true)
        let reviewModel = BlockingMemoryReviewModel()
        let review = Task {
            await model.review(
                conversationID: UUID(), messages: [.init(role: .user, text: "Remember concise replies")],
                model: reviewModel, wait: true)
        }
        await reviewModel.waitUntilEntered()

        model.suspend()
        model.resume()
        await reviewModel.release()
        await review.value

        #expect(await store.reviewApplyCount == 0)
        #expect(model.state.entries.isEmpty)
    }

    @Test func skillPackagesPersistWithoutChangingLegacySkillRows() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = SkillPersistence(context: container.mainContext)
        let skill = AgentSkill(
            name: "example", summary: "Example", body: "Example",
            package: .init(frontmatter: "metadata:\n  owner: team", files: ["assets/raw": Data([0, 255])]))
        try persistence.save([skill])
        #expect(try persistence.load() == [skill])
        try persistence.save([])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentSkillPackage>()) == 0)
    }

    @Test func olderSyncPayloadCannotDiscardSupportingFiles() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let defaults = UserDefaults(suiteName: "skill-sync-\(UUID())")!
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        let skill = AgentSkill(
            name: "example", summary: "Example", body: "Original",
            package: .init(files: ["references/guide": Data("Keep".utf8)]))
        try store.saveSkills([skill])
        var legacy = skill
        legacy.package = nil
        legacy.body = "Edited on an old client"
        let payload = SettingsRecordPayload.skill(legacy, sortIndex: 0)
        let result = try store.applyRemote([
            SettingsEnvelope(
                key: payload.key,
                version: .init(modifiedAt: .now.addingTimeInterval(60), counter: 1, writerID: UUID()), payload: payload)
        ])
        #expect(result.snapshot.skills.first?.body == legacy.body)
        #expect(result.snapshot.skills.first?.package == skill.package)
        #expect(result.needsUpload.contains(payload.key))
    }

    @Test func skillImporterRejectsSymbolicLinks() throws {
        let url = directory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appending(path: "original.md")
        try Data("---\nname: example\ndescription: Example\n---\nBody".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: url.appending(path: "SKILL.md"), withDestinationURL: file)
        #expect(throws: (any Error).self) { try SkillImporter.read(url) }
    }

    @Test func failedDestroyStaysDisabledAndStartupRetriesIt() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "destroy-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = GRDBMemoryStore(directory: url)
        let failing = FailingDestroyStore(base: base)
        let model = MemoryModel(storage: failing, defaults: defaults)
        await model.setEnabled(true)
        await model.destroy()
        #expect(!model.isEnabled)
        #expect(model.error != nil)
        #expect(defaults.bool(forKey: "hermesMemoryDestroyPending"))
        await model.setEnabled(true)
        #expect(!model.isEnabled)
        let restarted = MemoryModel(storage: base, defaults: defaults)
        for _ in 0..<200 where defaults.bool(forKey: "hermesMemoryDestroyPending") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!restarted.isEnabled)
        #expect(!defaults.bool(forKey: "hermesMemoryDestroyPending"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private actor MemoryLifecycleStore: MemoryPersisting {
    private var memory = AgentMemoryState()
    private var historyReplacements: [[StoredAgentConversation]] = []
    private(set) var reviewApplyCount = 0

    var historyReplacementCount: Int { historyReplacements.count }
    var lastHistory: [StoredAgentConversation]? { historyReplacements.last }

    func rebuildHistoryIndex() {}
    func memoryState() -> AgentMemoryState { memory }
    func applyMemory(_ operations: [AgentMemoryOperation]) throws -> AgentMemoryState {
        memory = try memory.applying(operations)
        return memory
    }
    func snapshot(for id: UUID) -> String { memory.prompt }
    func replaceHistory(_ conversations: [StoredAgentConversation]) { historyReplacements.append(conversations) }
    func searchSessions(_ request: AgentSessionSearchRequest) -> AgentJSONValue { .array([]) }
    func lastReviewedMessage(_ id: UUID) -> UUID? { nil }
    func markReviewed(_ messageID: UUID, conversationID: UUID) {}
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID
    ) throws -> AgentMemoryState? {
        reviewApplyCount += 1
        guard memory == expected else { return nil }
        memory = try memory.applying(operations)
        return memory
    }
    func replaceTarget(_ target: AgentMemoryTarget, text: String) -> AgentMemoryState { memory }
    func close() {}
    func destroy() { memory = .init() }
}

private actor BlockingMemoryReviewModel: AgentModelCompleting {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return [
            .textDelta(#"{"operations":[{"action":"add","target":"user","content":"Likes concise replies"}]}"#),
            .finished(.completed),
        ]
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw MemoryLifecycleTestTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private struct MemoryLifecycleTestTimeout: Error {}

private struct FailingDestroyStore: MemoryPersisting {
    let base: GRDBMemoryStore
    func rebuildHistoryIndex() async throws { try await base.rebuildHistoryIndex() }
    func memoryState() async throws -> AgentMemoryState { try await base.memoryState() }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState {
        try await base.applyMemory(operations)
    }
    func snapshot(for id: UUID) async throws -> String { try await base.snapshot(for: id) }
    func replaceHistory(_ conversations: [StoredAgentConversation]) async throws {
        try await base.replaceHistory(conversations)
    }
    func searchSessions(_ request: AgentSessionSearchRequest) async throws -> AgentJSONValue {
        try await base.searchSessions(request)
    }
    func lastReviewedMessage(_ id: UUID) async throws -> UUID? { try await base.lastReviewedMessage(id) }
    func markReviewed(_ messageID: UUID, conversationID: UUID) async throws {
        try await base.markReviewed(messageID, conversationID: conversationID)
    }
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID
    ) async throws -> AgentMemoryState? {
        try await base.applyReview(operations, expected: expected, messageID: messageID, conversationID: conversationID)
    }
    func replaceTarget(_ target: AgentMemoryTarget, text: String) async throws -> AgentMemoryState {
        try await base.replaceTarget(target, text: text)
    }
    func close() async throws { try await base.close() }
    func destroy() async throws { throw CocoaError(.fileWriteNoPermission) }
}
