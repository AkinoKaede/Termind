import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentPersistenceTests {
    @Test
    func versionEightMessagesMigrateWithAnEmptyImageList() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TermindImageMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Termind.store")
        let messageID = UUID()

        do {
            let schema = Schema(versionedSchema: TermindSchemaV8.self)
            let configuration = ModelConfiguration("Migration", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let row = TermindSchemaV8Models.PersistentAgentMessage()
            row.id = messageID
            row.text = "Before images"
            container.mainContext.insert(row)
            try container.mainContext.save()
        }

        let configuration = ModelConfiguration(
            "Migration", schema: HostPersistence.schema, url: storeURL
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, migrationPlan: TermindMigrationPlan.self,
            configurations: [configuration]
        )
        let row = try #require(
            container.mainContext.fetch(FetchDescriptor<PersistentAgentMessage>()).first
        )

        #expect(row.id == messageID)
        #expect(row.text == "Before images")
        #expect(row.imagesData.isEmpty)
    }

    @Test
    func imagePartsRoundTripThroughConversationPersistence() async throws {
        let configuration = ModelConfiguration(
            "AgentImagePersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let image = AgentImageAttachment(
            label: "screen.png", mimeType: "image/png", data: Data([4, 5, 6]),
            pixelWidth: 80, pixelHeight: 60
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .user, text: "Look", images: [image])]
        )

        try await repository.save(snapshot)
        let restored = try await repository.loadConversations()

        #expect(restored.first?.messages.first?.images == [image])
    }

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
    func fetchHeaderSecretsAreRedactedFromToolCallsAndInvocationRows() async throws {
        let configuration = ModelConfiguration(
            "AgentFetchHeaderRedactionTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let arguments: AgentJSONValue = .object([
            "url": .string("https://example.test"),
            "headers": .array([
                .object([
                    "name": .string("Authorization"),
                    "value": .string("Bearer durable-secret"),
                ]),
                .object(["name": .string("X-Trace"), "value": .string("visible")]),
            ]),
        ])
        let call = AgentToolCall(id: "fetch", name: "fetch", arguments: arguments)
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .assistant, toolCalls: [call])]
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(runID: snapshot.id, call: call)
        try await repository.record(
            .toolProposed(invocation, AgentToolDescriptor(
                name: "fetch", summary: "fetch", inputSchema: .object([:]),
                target: .network, safety: .locallyReadOnly
            )),
            runID: snapshot.id
        )

        let message = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentMessage>()
        ).first)
        let invocationRow = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentToolInvocation>()
        ).first)
        for data in [message.toolCallsData, invocationRow.argumentsData] {
            let stored = String(decoding: data, as: UTF8.self)
            #expect(!stored.contains("durable-secret"))
            #expect(stored.contains("[REDACTED]"))
            #expect(stored.contains("visible"))
        }
    }

    /// A conversation replays its earlier turns into every later run, so a save
    /// that matched stored rows by run id re-inserted the whole history on each
    /// turn — colliding with the unique constraint and rewriting rows that were
    /// already correct.
    @Test
    func replayedHistoryIsNotRewrittenByEveryLaterRun() async throws {
        let configuration = ModelConfiguration(
            "AgentPersistenceReplayTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()

        // Explicit times: a real run separates its messages by a round trip,
        // and ordering ties are not what this test is about.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let opening = AgentTranscriptMessage(
            role: .user, text: "list my hosts", createdAt: start
        )
        let answer = AgentTranscriptMessage(
            role: .assistant, text: "host-a", createdAt: start.addingTimeInterval(1)
        )
        var first = AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval, messages: [opening, answer]
        )
        first.finishedAt = .now
        try await repository.save(first)

        // The second run carries the first run's messages as prior context.
        var second = AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval,
            messages: [
                opening, answer,
                AgentTranscriptMessage(
                    role: .user, text: "connect to it",
                    createdAt: start.addingTimeInterval(2)
                ),
            ]
        )
        second.finishedAt = .now
        try await repository.save(second)

        let rows = try container.mainContext.fetch(FetchDescriptor<PersistentAgentMessage>())
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        // The replayed rows still belong to the run that first wrote them.
        #expect(rows.first { $0.id == opening.id }?.runID == first.id)
        #expect(rows.first { $0.id == answer.id }?.runID == first.id)

        let restored = try await repository.loadConversations()
        #expect(restored.count == 1)
        #expect(restored.first?.messages.map(\.text) == ["list my hosts", "host-a", "connect to it"])
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

    /// A stored title means "the generated summary", so saving a run must leave
    /// it empty. Seeding it from the opening line froze that line into storage
    /// as though it were a name someone had chosen, and nothing ever read it
    /// back to notice.
    @Test
    func aTitleIsWrittenOnlyBySummaryAndSurvivesRestore() async throws {
        let configuration = ModelConfiguration(
            "AgentPersistenceTitleTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        try await repository.save(AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval,
            messages: [
                AgentTranscriptMessage(role: .user, text: "Root is at 99%"),
                AgentTranscriptMessage(role: .assistant, text: "Start with du."),
            ]
        ))

        #expect(try await repository.loadConversations().first?.title == "")

        try await repository.setTitle("Root volume filling up", conversationID: conversationID)

        #expect(try await repository.loadConversations().first?.title == "Root volume filling up")

        // The summary is model output about remote-influenced text, so it goes
        // through the same redaction as every other stored string.
        try await repository.setTitle("token=abcd1234", conversationID: conversationID)
        let redacted = try await repository.loadConversations().first?.title ?? ""
        #expect(!redacted.contains("abcd1234"))

        try await repository.deleteConversation(conversationID)
        try await repository.setTitle("late", conversationID: conversationID)
        #expect(try await repository.loadConversations().isEmpty)
    }
}
