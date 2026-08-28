import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentPersistenceTests {

    @Test
    func toolDetailPresenterSurvivesPersistenceAndRestoresTheSameDetail() async throws {
        let configuration = localModelConfiguration(
            "AgentDetailPresenterPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let call = AgentToolCall(
            id: "search", name: "web_search",
            arguments: .object(["query": .string("example")])
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .assistant, text: "", toolCalls: [call])]
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(runID: snapshot.id, call: call)
        let presentation = AgentToolDescriptor.Presentation(
            symbol: "magnifyingglass",
            activity: .semanticArgument(key: "query", fallback: .web), output: .json,
            detailPresenterID: "builtin.web_search", actionKind: .search
        )
        let descriptor = AgentToolDescriptor(
            name: call.name, summary: "Search", inputSchema: .object([:]),
            target: .network, safety: .locallyReadOnly, presentation: presentation
        )
        var result = AgentToolResult(
            callID: call.id,
            content: AgentJSONValue.array([.object([
                "title": .string("Example"), "url": .string("https://example.com"),
                "snippet": .string("A result"), "published_at": .null,
            ])]).encodedString
        )
        result.toolPresentation = presentation
        try await repository.record(.toolProposed(invocation, descriptor), runID: snapshot.id)
        try await repository.record(.toolFinished(invocation, result), runID: snapshot.id)

        let stored = try #require(
            try await repository.loadConversations().first?.toolCards.first
        )
        let restored = AgentToolCard(
            invocation: stored.invocation, descriptor: stored.descriptor,
            state: .completed, result: stored.result, review: stored.review
        )
        let live = AgentToolCard(
            invocation: invocation, descriptor: descriptor,
            state: .completed, result: result
        )
        let locale = Locale(identifier: "en")
        #expect(
            AgentToolPresentation.detail(for: restored, locale: locale)
                == AgentToolPresentation.detail(for: live, locale: locale)
        )
        #expect(restored.descriptor.presentation?.detailPresenterID == "builtin.web_search")
    }

    @Test
    func imagePartsRoundTripThroughConversationPersistence() async throws {
        let configuration = localModelConfiguration(
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
    func contextAttachmentsRoundTripThroughConversationPersistence() async throws {
        let configuration = localModelConfiguration(
            "AgentContextAttachmentPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let attachment = AgentContextAttachment(
            kind: .file, label: "manual.pdf", contentTypeIdentifier: "com.adobe.pdf",
            suggestedFilename: "manual.pdf", data: Data([0x25, 0x50, 0x44, 0x46])
        )
        let message = AgentTranscriptMessage(
            role: .user, text: "\n\n<file label=\"manual.pdf\">\nText\n</file>",
            contextAttachments: [attachment]
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval, messages: [message]
        )

        try await repository.save(snapshot)
        let restored = try await repository.loadConversations()

        #expect(restored.first?.messages.first?.contextAttachments == [attachment])
        #expect(try container.mainContext.fetch(
            FetchDescriptor<PersistentAgentContextAttachments>()
        ).count == 1)

        try await repository.deleteConversation(snapshot.conversationID)
        #expect(try container.mainContext.fetch(
            FetchDescriptor<PersistentAgentContextAttachments>()
        ).isEmpty)
    }

    @Test
    func schemaV2MigratesToV3WithEmptyAttachmentBacking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindAgentV3Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: TermindSchemaV2.self)
        let conversationID = UUID()

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration("Migration", schema: legacySchema, url: storeURL)
            ]
        )
        legacyContainer?.mainContext.insert(PersistentAgentConversation(
            id: conversationID, title: "Existing"
        ))
        try legacyContainer?.mainContext.save()
        legacyContainer = nil

        let migrated = try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [
                localModelConfiguration(
                    "Migration", schema: HostPersistence.schema, url: storeURL
                )
            ]
        )

        #expect(try migrated.mainContext.fetch(
            FetchDescriptor<PersistentAgentConversation>()
        ).map(\.id) == [conversationID])
        #expect(try migrated.mainContext.fetch(
            FetchDescriptor<PersistentAgentContextAttachments>()
        ).isEmpty)
    }

    @Test
    func displayReasoningRoundTripsRedactedWithoutProviderState() async throws {
        let configuration = localModelConfiguration(
            "AgentReasoningPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let createdAt = Date(timeIntervalSince1970: 1_234)
        let block = AgentReasoningBlock(
            text: "Inspect token=durable-secret before answering.", createdAt: createdAt
        )
        let message = AgentTranscriptMessage(
            role: .assistant, text: "Done", reasoning: [block],
            providerItems: [.object([
                "signature": .string("opaque-provider-signature"),
            ])]
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval, messages: [message]
        )

        try await repository.save(snapshot)

        let row = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentMessage>()
        ).first)
        let storedReasoning = String(decoding: row.reasoningData, as: UTF8.self)
        #expect(!storedReasoning.contains("durable-secret"))
        #expect(!storedReasoning.contains("opaque-provider-signature"))

        let restored = try #require(try await repository.loadConversations().first)
        let restoredBlock = try #require(restored.messages.first?.reasoning.first)
        #expect(restoredBlock.id == block.id)
        #expect(restoredBlock.createdAt == createdAt)
        #expect(restoredBlock.text.contains("[REDACTED]"))
        #expect(restored.messages.first?.providerItems.isEmpty == true)
    }

    @Test
    func runOwnershipAndToolSourceMessageRoundTrip() async throws {
        let configuration = localModelConfiguration(
            "AgentWorkPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let user = AgentTranscriptMessage(role: .user, text: "Search")
        let assistant = AgentTranscriptMessage(
            role: .assistant, text: "Searching",
            toolCalls: [AgentToolCall(id: "call", name: "web_search", arguments: .object([:]))]
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval, messages: [user, assistant],
            startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(8)
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(
            runID: snapshot.id, call: assistant.toolCalls[0],
            sourceMessageID: assistant.id
        )
        let descriptor = AgentToolDescriptor(
            name: "web_search", summary: "Search", inputSchema: .object([:]),
            target: .network, safety: .locallyReadOnly
        )
        try await repository.record(.toolProposed(invocation, descriptor), runID: snapshot.id)
        try await repository.record(.toolFinished(
            invocation, AgentToolResult(callID: "call", content: "[]")
        ), runID: snapshot.id)

        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messageRunIDs[user.id] == snapshot.id)
        #expect(restored.messageRunIDs[assistant.id] == snapshot.id)
        #expect(restored.runs.first?.startedAt == startedAt)
        #expect(restored.runs.first?.finishedAt == startedAt.addingTimeInterval(8))
        #expect(restored.toolCards.first?.invocation.sourceMessageID == assistant.id)
    }

    @Test
    func unfinishedRunsInterruptAndVisibleHistoryRestoresWithoutSecrets() async throws {
        let configuration = localModelConfiguration(
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
        let configuration = localModelConfiguration(
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

    @Test
    func optionalSecretNullRemainsAbsentAcrossPersistence() async throws {
        let configuration = localModelConfiguration(
            "AgentOptionalSecretPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let call = AgentToolCall(
            id: "exec", name: "ssh_exec",
            arguments: .object([
                "host_id": .string(UUID().uuidString),
                "command": .string("uptime"),
                "secret_handle": .null,
                "stdin_purpose": .null,
            ])
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .assistant, toolCalls: [call])]
        )

        try await repository.save(snapshot)

        let restored = try #require(
            try await repository.loadConversations().first?.messages.first?.toolCalls.first
        )
        #expect(restored.arguments.objectValue?["secret_handle"] == .null)
        #expect(!restored.arguments.encodedString.contains("[REDACTED]"))
    }

    @Test
    func requestUserSecretHandleIsNeverWrittenToDurableHistory() async throws {
        let configuration = localModelConfiguration(
            "AgentSecretHandlePersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let handle = UUID().uuidString
        let call = AgentToolCall(
            id: "secret", name: "request_user_secret", arguments: .object([:])
        )
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let toolResult = AgentTranscriptMessage(
            role: .tool,
            text: "<untrusted-data>\n{\"secret_handle\":\"\(handle)\",\"single_use\":true}\n</untrusted-data>",
            toolCallID: call.id, toolName: call.name
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval, messages: [assistant, toolResult]
        )
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(runID: snapshot.id, call: call)
        try await repository.record(
            .toolFinished(
                invocation,
                AgentToolResult(callID: call.id, content: toolResult.text)
            ),
            runID: snapshot.id
        )

        let storedMessages = try container.mainContext.fetch(
            FetchDescriptor<PersistentAgentMessage>()
        )
        let storedResult = try #require(container.mainContext.fetch(
            FetchDescriptor<PersistentAgentToolResult>()
        ).first)
        let durableText = storedMessages.map(\.text).joined() + storedResult.content
        #expect(!durableText.contains(handle))
        #expect(durableText.contains("expired"))

        let restored = try #require(try await repository.loadConversations().first)
        let restoredResult = try #require(restored.messages.first { $0.role == .tool })
        #expect(restoredResult.text == AgentSecretLifecycle.expiredResultContent)
    }

    /// A conversation replays its earlier turns into every later run, so a save
    /// that matched stored rows by run id re-inserted the whole history on each
    /// turn — colliding with the unique constraint and rewriting rows that were
    /// already correct.
    @Test
    func replayedHistoryIsNotRewrittenByEveryLaterRun() async throws {
        let configuration = localModelConfiguration(
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
        let configuration = localModelConfiguration(
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
        let configuration = localModelConfiguration(
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
        let configuration = localModelConfiguration(
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

    @Test
    func metadataAndAuthoredTextSurviveRestore() async throws {
        let configuration = localModelConfiguration(
            "AgentConversationMetadataTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let id = UUID()
        try await repository.save(AgentRunSnapshot(
            conversationID: id, state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(
                role: .user, text: "Prompt\n\n<file label=\"a\">payload</file>",
                authoredText: "Prompt"
            )]
        ))
        let archived = Date(timeIntervalSince1970: 10)
        try await repository.setConversationMetadata(
            StoredAgentConversationMetadata(
                customTitle: "Named", isPinned: false, archivedAt: archived,
                createdAt: .now, updatedAt: .now
            ), conversationID: id
        )

        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.first?.authoredText == "Prompt")
        #expect(restored.metadata.customTitle == "Named")
        #expect(restored.metadata.archivedAt == archived)
    }

    @Test
    func manualConversationOrderAndPinnedStatePersistAtomically() async throws {
        let configuration = localModelConfiguration(
            "AgentConversationOrderTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let first = UUID()
        let second = UUID()
        for id in [first, second] {
            try await repository.save(AgentRunSnapshot(
                conversationID: id, state: .completed,
                permissionMode: .askForApproval, messages: []
            ))
        }

        try await repository.reorderConversations([
            StoredAgentConversationOrder(id: first, isPinned: true, sortIndex: 0),
            StoredAgentConversationOrder(id: second, isPinned: false, sortIndex: 1),
        ])

        let restored = try await repository.loadConversations()
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.metadata) })
        #expect(byID[first]?.isPinned == true)
        #expect(byID[first]?.sortIndex == 0)
        #expect(byID[second]?.isPinned == false)
        #expect(byID[second]?.sortIndex == 1)
    }

    @Test
    func truncationRemovesTheTargetRunAndEverythingAfterIt() async throws {
        let configuration = localModelConfiguration(
            "AgentConversationTruncationTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let id = UUID()
        let firstUser = AgentTranscriptMessage(role: .user, text: "One", authoredText: "One")
        let firstAssistant = AgentTranscriptMessage(role: .assistant, text: "Answer one")
        var first = AgentRunSnapshot(
            conversationID: id, state: .completed, permissionMode: .askForApproval,
            messages: [firstUser, firstAssistant], startedAt: Date(timeIntervalSince1970: 1)
        )
        first.finishedAt = Date(timeIntervalSince1970: 2)
        try await repository.save(first)
        let secondUser = AgentTranscriptMessage(role: .user, text: "Two", authoredText: "Two")
        var second = AgentRunSnapshot(
            conversationID: id, state: .completed, permissionMode: .askForApproval,
            messages: [firstUser, firstAssistant, secondUser],
            startedAt: Date(timeIntervalSince1970: 3)
        )
        second.finishedAt = Date(timeIntervalSince1970: 4)
        try await repository.save(second)

        try await repository.truncateConversation(
            id, fromUserMessageID: secondUser.id,
            replacingWith: AgentTranscriptMessage(
                role: .user, text: "Edited", authoredText: "Edited"
            )
        )

        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.map(\.text) == ["One", "Answer one", "Edited"])
    }

    @Test
    func truncationRejectsAMessageOutsideThePersistedConversation() async throws {
        let configuration = localModelConfiguration(
            "AgentConversationMissingEditTargetTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let id = UUID()
        let original = AgentTranscriptMessage(
            role: .user, text: "Original", authoredText: "Original"
        )
        try await repository.save(AgentRunSnapshot(
            conversationID: id, state: .completed,
            permissionMode: .askForApproval, messages: [original]
        ))

        await #expect(throws: AgentConversationPersistenceError.self) {
            try await repository.truncateConversation(
                id, fromUserMessageID: UUID(),
                replacingWith: AgentTranscriptMessage(
                    role: .user, text: "Edited", authoredText: "Edited"
                )
            )
        }

        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.map(\.id) == [original.id])
        #expect(restored.messages.map(\.text) == ["Original"])
    }

    @Test
    func creatingAForkPersistsAnIndependentConversationGraph() async throws {
        let configuration = localModelConfiguration(
            "AgentConversationForkTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let originalID = UUID()
        let forkID = UUID()
        let originalMessageID = UUID()
        let forkMessageID = UUID()
        try await repository.save(AgentRunSnapshot(
            conversationID: originalID, state: .completed,
            permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(
                id: originalMessageID, role: .user, text: "Original", authoredText: "Original"
            )]
        ))
        try await repository.createConversation(StoredAgentConversation(
            id: forkID,
            messages: [AgentTranscriptMessage(
                id: forkMessageID, role: .user, text: "Original", authoredText: "Original"
            )], lastRunState: .completed,
            metadata: StoredAgentConversationMetadata(customTitle: "Original (1)")
        ))

        let restored = try await repository.loadConversations()
        #expect(Set(restored.map(\.id)) == Set([originalID, forkID]))
        #expect(restored.first { $0.id == forkID }?.messages.first?.id == forkMessageID)
        #expect(restored.first { $0.id == forkID }?.metadata.customTitle == "Original (1)")

        try await repository.deleteConversation(originalID)
        #expect(try await repository.loadConversations().map(\.id) == [forkID])
    }
}
