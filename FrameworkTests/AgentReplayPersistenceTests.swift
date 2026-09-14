import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct AgentReplayPersistenceTests {
    @Test
    func snapshotsAndFrozenResultsSurviveRestoreAndDeletion() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let first = AgentTranscriptMessage(
            role: .user, text: "inspect", authoredText: "inspect",
            contextSnapshot: .init(sessionContext: "host A", skillCatalog: "skills", planContract: "plan")
        )
        let call = AgentToolCall(id: "inspect", name: "inspect", arguments: .object([:]))
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let result = AgentTranscriptMessage(
            role: .tool, text: "complete captured result", toolCallID: call.id, toolName: call.name,
            modelText: "fixed preview"
        )
        var snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed, permissionMode: .askForApproval,
            messages: [first, assistant, result]
        )
        try await repository.save(snapshot)
        // A subsequent run must neither overwrite an earlier snapshot nor duplicate its backing.
        snapshot.id = UUID()
        snapshot.messages.append(.init(role: .user, text: "continue", contextSnapshot: .init()))
        try await repository.save(snapshot)
        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.first?.contextSnapshot == first.contextSnapshot)
        #expect(restored.messages.first?.text == "inspect")
        #expect(restored.messages.first { $0.role == .tool }?.modelText == "fixed preview")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentMessageReplay>()) == 3)
        let model = ConversationModel(messages: [], transcript: restored.messages)
        let editable = try #require(model.editedUserMessage(first.id, authoredText: "edited"))
        #expect(editable.text == "edited")
        #expect(editable.contextSnapshot == nil)
        try await repository.deleteConversation(snapshot.conversationID)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentMessageReplay>()) == 0)
    }

    @Test
    func aResultRecordedBeforeItsSnapshotKeepsTheModelProjection() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let call = AgentToolCall(id: "read", name: "read", arguments: .object([:]))
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed, permissionMode: .askForApproval, messages: [assistant]
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(runID: snapshot.id, call: call, sourceMessageID: assistant.id)
        var result = AgentToolResult(callID: call.id, content: "full captured result")
        result.modelContent = "frozen preview"
        try await repository.record(.toolFinished(invocation, result), runID: snapshot.id)
        let restored = try #require(try await repository.loadConversations().first?.messages.last)
        #expect(restored.modelText == "frozen preview")
        #expect(restored.id == AgentTranscriptMessage.toolResultID(runID: snapshot.id, callID: call.id))
    }

    @Test
    func v15MigratesWithoutInventingHistoricalContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        try seedLegacyStore(url)
        let container = try TermindPersistence.makeContainer(url: url)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.first?.text == "legacy")
        #expect(restored.messages.first?.contextSnapshot == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentMessageReplay>()) == 0)
    }

    private func seedLegacyStore(_ url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV15.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)]
        )
        let snapshot = AgentRunSnapshot(conversationID: UUID(), state: .completed, permissionMode: .askForApproval)
        container.mainContext.insert(PersistentAgentConversation(id: snapshot.conversationID, title: ""))
        container.mainContext.insert(PersistentAgentRun(snapshot))
        container.mainContext.insert(
            PersistentAgentMessage(.init(role: .user, text: "legacy"), runID: snapshot.id, sequence: 0))
        try container.mainContext.save()
    }
}
