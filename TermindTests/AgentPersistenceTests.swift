import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentPersistenceTests {
    @Test
    func unfinishedRunsInterruptAndVisibleHistoryRestoresWithoutSecrets() async throws {
        let configuration = ModelConfiguration(
            "AgentPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        var snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .running,
            permissionMode: .approveForMe,
            messages: [AgentTranscriptMessage(
                role: .user, text: "deploy password=hunter2"
            )]
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(
            runID: snapshot.id,
            call: AgentToolCall(
                id: "call", name: "ssh_exec",
                arguments: .object([
                    "password": .string("hunter2"), "command": .string("uptime"),
                ])
            )
        )
        try await repository.record(
            .toolProposed(invocation, AgentToolDescriptor(
                name: "ssh_exec", summary: "exec", inputSchema: .object([:]),
                target: .host, safety: .requiresAuthorization
            )),
            runID: snapshot.id
        )

        _ = SwiftDataAgentRunRepository(context: container.mainContext)
        let run = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentRun>()
        ).first)
        #expect(run.state == AgentRunState.interrupted.rawValue)
        let message = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentMessage>()
        ).first)
        #expect(!message.text.contains("hunter2"))
        let tool = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentToolInvocation>()
        ).first)
        #expect(!String(decoding: tool.argumentsData, as: UTF8.self).contains("hunter2"))

        snapshot.state = .interrupted
        let restored = try await repository.loadConversations()
        #expect(restored.first?.id == snapshot.conversationID)
        #expect(restored.first?.lastRunState == .interrupted)
        #expect(restored.first?.toolCards.count == 1)
        #expect(
            restored.first?.toolCards.first?.invocation.call.arguments.encodedString
                .contains("hunter2") == false
        )
    }

    @Test
    func outOfOrderPersistenceEventsNeverDowngradeToolState() async throws {
        let configuration = ModelConfiguration(
            "AgentPersistenceEventOrderTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "call", name: "ssh_exec", arguments: .object([:]))
        )
        try await repository.record(
            .toolFinished(invocation, AgentToolResult(callID: "call", content: "done")),
            runID: invocation.runID
        )
        try await repository.record(
            .toolProposed(invocation, AgentToolDescriptor(
                name: "ssh_exec", summary: "exec", inputSchema: .object([:]),
                target: .host, safety: .requiresAuthorization
            )),
            runID: invocation.runID
        )

        let row = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentToolInvocation>()
        ).first)
        #expect(row.state == "finished")
    }

    @Test
    func deletingConversationRemovesItsCompletePersistentGraph() async throws {
        let configuration = ModelConfiguration(
            "AgentPersistenceDeletionTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let snapshot = AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .user, text: "List hosts")]
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(
            runID: snapshot.id,
            call: AgentToolCall(id: "call", name: "list_hosts", arguments: .object([:]))
        )
        try await repository.record(
            .toolFinished(invocation, AgentToolResult(callID: "call", content: "[]")),
            runID: snapshot.id
        )
        let request = AgentApprovalRequest(
            invocation: invocation,
            descriptor: AgentToolDescriptor(
                name: "list_hosts", summary: "List", inputSchema: .object([:]),
                target: .local, safety: .locallyReadOnly
            ),
            userIntent: "List hosts"
        )
        try await repository.record(
            .reviewFinished(request, SecurityReviewDecision(
                verdict: .approve, risk: .low, userAuthorization: .sufficient,
                reason: "Allowed"
            )),
            runID: snapshot.id
        )

        try await repository.deleteConversation(conversationID)

        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAgentConversation>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAgentRun>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAgentMessage>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAgentToolInvocation>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAgentToolResult>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAgentReviewRecord>()).isEmpty)
        #expect(try await repository.loadConversations().isEmpty)
    }
}
