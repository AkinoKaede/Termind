// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentPersistenceTests {

    @Test
    func resourceCardsRetainPublicNamesWithoutRequiringAPresenterAfterReload() async throws {
        let configuration = localModelConfiguration(
            "ResourceCardPersistenceTests", schema: HostPersistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: HostPersistence.schema, configurations: [configuration])
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let id = UUID().uuidString
        let call = AgentToolCall(
            id: "deleted", name: TermindToolName.deleteKey, arguments: .object(["key_id": .string(id)]))
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed, permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .assistant, toolCalls: [call])])
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(runID: snapshot.id, call: call)
        let descriptor = AgentToolDescriptor(
            name: call.name, summary: "Delete key", inputSchema: .object([:]), target: .local, approvalPolicy: .ask)
        let result = AgentToolResult(
            callID: call.id,
            content: AgentJSONValue.object(["id": .string(id), "deleted": .bool(true)]).encodedString,
            metadata: ["resource_display_names": .object([id: .string("Old deployment key")])])
        try await repository.record(.toolProposed(invocation, descriptor), runID: snapshot.id)
        try await repository.record(.toolFinished(invocation, result), runID: snapshot.id)
        let stored = try #require(try await repository.loadConversations().first?.toolCards.first)
        let card = AgentToolCard(
            invocation: stored.invocation, descriptor: stored.descriptor,
            state: .completed, result: stored.result)
        let content = try #require(ResourceToolCardPresentation.content(for: card, locale: Locale(identifier: "en")))
        #expect(content.title == "Old deployment key")
        #expect(AgentToolDetailPreview(content.detail).fullText.contains("Resource deleted"))
    }

    @Test
    func credentialWriteHandlesAreRedactedFromReloadedMessagesAndToolCards() async throws {
        let configuration = localModelConfiguration(
            "ResourceSecretPersistenceTests", schema: HostPersistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: HostPersistence.schema, configurations: [configuration])
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let handles = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
        let call = AgentToolCall(
            id: "credentials", name: TermindToolName.editKey,
            arguments: .object([
                "key_id": .string(UUID().uuidString),
                "password_secret_handle": .string(handles[0]),
                "private_key_secret_handle": .string(handles[1]),
                "passphrase_secret_handle": .string(handles[2]),
            ]))
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed, permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .assistant, toolCalls: [call])])
        try await repository.save(snapshot)
        let invocation = AgentToolInvocation(runID: snapshot.id, call: call)
        let descriptor = AgentToolDescriptor(
            name: call.name, summary: "Update credentials", inputSchema: .object([:]), target: .local,
            approvalPolicy: .ask)
        try await repository.record(.toolProposed(invocation, descriptor), runID: snapshot.id)
        try await repository.record(
            .toolFinished(invocation, .init(callID: call.id, content: "{\"saved\":true}")), runID: snapshot.id)
        let reloaded = try #require(try await repository.loadConversations().first)
        let stored = String(describing: reloaded.messages) + String(describing: reloaded.toolCards)
        for handle in handles { #expect(!stored.contains(handle)) }
        #expect(!reloaded.toolCards.isEmpty)
    }

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
            presenterID: "builtin.web_search", actionKind: .search
        )
        let descriptor = AgentToolDescriptor(
            name: call.name, summary: "Search", inputSchema: .object([:]),
            target: .network, approvalPolicy: .approve, presentation: presentation
        )
        var result = AgentToolResult(
            callID: call.id,
            content: AgentJSONValue.array([
                .object([
                    "title": .string("Example"), "url": .string("https://example.com"),
                    "snippet": .string("A result"), "published_at": .null,
                ])
            ]).encodedString
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
            TermindToolPresentationProfiles.renderer.detail(
                for: restored, presenter: TermindAgentTools.presenter(for: restored.descriptor), locale: locale)
                == TermindToolPresentationProfiles.renderer.detail(
                    for: live, presenter: TermindAgentTools.presenter(for: live.descriptor), locale: locale)
        )
        #expect(restored.descriptor.presentation?.presenterID == "builtin.web_search")
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
        #expect(
            try container.mainContext.fetch(
                FetchDescriptor<PersistentAgentContextAttachments>()
            ).count == 1)

        try await repository.deleteConversation(snapshot.conversationID)
        #expect(
            try container.mainContext.fetch(
                FetchDescriptor<PersistentAgentContextAttachments>()
            ).isEmpty)
    }

    @Test
    func schemaV2MigratesToV3WithEmptyAttachmentBacking() throws {
        try expectMigrationKeepsConversationAndLeavesEmptyBacking(
            from: TermindSchemaV2.self, backing: PersistentAgentContextAttachments.self)
    }

    @Test
    func schemaV8MigratesToV9WithEmptyCompactionBacking() throws {
        try expectMigrationKeepsConversationAndLeavesEmptyBacking(
            from: TermindSchemaV8.self, backing: PersistentAgentCompaction.self)
    }

    private func expectMigrationKeepsConversationAndLeavesEmptyBacking<Backing: PersistentModel>(
        from legacy: any VersionedSchema.Type, backing: Backing.Type
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindAgentMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: legacy)
        let conversationID = UUID()

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration("Migration", schema: legacySchema, url: storeURL)
            ]
        )
        legacyContainer?.mainContext.insert(
            PersistentAgentConversation(
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

        #expect(
            try migrated.mainContext.fetch(
                FetchDescriptor<PersistentAgentConversation>()
            ).map(\.id) == [conversationID])
        #expect(try migrated.mainContext.fetch(FetchDescriptor<Backing>()).isEmpty)
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
            providerItems: [
                .object([
                    "signature": .string("opaque-provider-signature")
                ])
            ]
        )
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed,
            permissionMode: .askForApproval, messages: [message]
        )

        try await repository.save(snapshot)

        let row = try #require(
            container.mainContext.fetch(
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
            target: .network, approvalPolicy: .approve
        )
        try await repository.record(.toolProposed(invocation, descriptor), runID: snapshot.id)
        try await repository.record(
            .toolFinished(
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
            messages: [
                AgentTranscriptMessage(
                    role: .user, text: "deploy password=hunter2"
                )
            ]
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
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "ssh_exec", summary: "exec", inputSchema: .object([:]),
                    target: .host, approvalPolicy: .ask
                )),
            runID: snapshot.id
        )

        _ = SwiftDataAgentRunRepository(context: container.mainContext)
        let run = try #require(
            container.mainContext.fetch(
                FetchDescriptor<PersistentAgentRun>()
            ).first)
        #expect(run.state == AgentRunState.interrupted.rawValue)
        let message = try #require(
            container.mainContext.fetch(
                FetchDescriptor<PersistentAgentMessage>()
            ).first)
        #expect(!message.text.contains("hunter2"))
        let tool = try #require(
            container.mainContext.fetch(
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
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "fetch", summary: "fetch", inputSchema: .object([:]),
                    target: .network, approvalPolicy: .approve
                )),
            runID: snapshot.id
        )

        let message = try #require(
            container.mainContext.fetch(
                FetchDescriptor<PersistentAgentMessage>()
            ).first)
        let invocationRow = try #require(
            container.mainContext.fetch(
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
        let storedResult = try #require(
            container.mainContext.fetch(
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
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "ssh_exec", summary: "exec", inputSchema: .object([:]),
                    target: .host, approvalPolicy: .ask
                )),
            runID: invocation.runID
        )

        let row = try #require(
            container.mainContext.fetch(
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
                target: .local, approvalPolicy: .approve
            ),
            userIntent: "List hosts"
        )
        try await repository.record(
            .reviewFinished(
                request,
                GuardianDecision(
                    verdict: .approve, risk: .low, userAuthorization: .high,
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
        try await repository.save(
            AgentRunSnapshot(
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
        try await repository.save(
            AgentRunSnapshot(
                conversationID: id, state: .completed,
                permissionMode: .askForApproval,
                messages: [
                    AgentTranscriptMessage(
                        role: .user, text: "Prompt\n\n<file label=\"a\">payload</file>",
                        authoredText: "Prompt"
                    )
                ]
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
            try await repository.save(
                AgentRunSnapshot(
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
    func liveRunSnapshotsCannotOverwriteManualOrder() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let prompt = AgentTranscriptMessage(role: .user, text: "Inspect")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: prompt.id, role: .user, text: prompt.text)],
            transcript: [prompt], runState: .running, sortIndex: 1)
        let peer = ConversationModel(sortIndex: 0)
        var snapshot = AgentRunSnapshot(
            conversationID: conversation.id, state: .running,
            permissionMode: .askForApproval, messages: [prompt])
        try await repository.save(snapshot)
        try await repository.save(
            AgentRunSnapshot(
                conversationID: peer.id, state: .completed,
                permissionMode: .askForApproval, messages: []))
        let library = AssistantLibraryModel(store: AssistantConversationStore(conversations: [peer, conversation]))
        let operations = AssistantConversationOperations(repository: repository)
        try await operations.move(conversation, pinned: false, before: peer.id, library: library)
        try await operations.move(conversation, pinned: true, before: nil, library: library)
        let response = AgentTranscriptMessage(role: .assistant, text: "Still working")
        snapshot.messages.append(response)
        try await repository.save(snapshot)
        conversation.handle(.messageDelta(messageID: response.id, text: response.text))
        #expect(conversation.messages.last?.text == "Still working")
        #expect(conversation.runState == .running)
        #expect(conversation.isPinned)
        #expect(conversation.sortIndex == 0)
        snapshot.state = .completed
        try await repository.save(snapshot)
        conversation.handle(.runState(.completed))
        let store = AssistantConversationStore()
        store.restore(try await repository.loadConversations())
        let restored = AssistantLibraryModel(store: store)
        #expect(restored.pinnedConversations.map(\.id) == [conversation.id])
        #expect(restored.pinnedConversations.first?.sortIndex == 0)
        #expect(restored.activeConversations.map(\.id) == [peer.id])
        #expect(restored.pinnedConversations.first?.messages.last?.text == response.text)
        #expect(library.conversation(id: conversation.id) === conversation)
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

    @Test(arguments: [false, true])
    func truncationRemovesSuffixTools(_ hasTranscriptCall: Bool) async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let runID = UUID()
        let instant = Date(timeIntervalSinceReferenceDate: 100)
        let opening = AgentTranscriptMessage(role: .user, text: "Opening", createdAt: instant)
        let steering = AgentTranscriptMessage(role: .user, text: "Steering", createdAt: instant)
        let call = AgentToolCall(id: "suffix", name: "inspect", arguments: .object([:]))
        let answer = AgentTranscriptMessage(
            role: .assistant, text: "Answer", toolCalls: hasTranscriptCall ? [call] : [], createdAt: instant)
        let messages = [opening, steering, answer]
        try await repository.save(
            AgentRunSnapshot(
                id: runID, conversationID: conversationID, state: .failed,
                permissionMode: .askForApproval, messages: messages,
                startedAt: instant, finishedAt: instant))
        let invocation = AgentToolInvocation(
            runID: runID, call: call,
            sourceMessageID: hasTranscriptCall ? answer.id : UUID(), createdAt: instant)
        let descriptor = AgentToolDescriptor(
            name: "inspect", summary: "Inspect", inputSchema: .object([:]),
            target: .local, approvalPolicy: .approve)
        try await repository.record(.toolProposed(invocation, descriptor), runID: runID)
        try await repository.record(
            .toolFinished(invocation, AgentToolResult(callID: call.id, content: "Result")), runID: runID)
        try await repository.record(
            .reviewFinished(
                AgentApprovalRequest(invocation: invocation, descriptor: descriptor, userIntent: "Inspect"),
                GuardianDecision(verdict: .approve, risk: .low, userAuthorization: .high, reason: "Allowed")),
            runID: runID)
        let before = try #require(try await repository.loadConversations().first)
        let replacement = AgentTranscriptMessage(role: .user, text: "Replacement")
        let store = AssistantConversationStore()
        store.restore([before])
        let live = try #require(store.conversations.first)
        #expect(live.canEditUserMessage(steering.id))
        #expect(
            try await AssistantConversationOperations(repository: repository).edit(
                live, messageID: steering.id, replacement: replacement) != nil)

        let reopened = SwiftDataAgentRunRepository(context: ModelContext(container))
        let after = try #require(try await reopened.loadConversations().first)
        let expectedIDs = [opening.id, replacement.id]
        #expect(after.messages.map(\.id) == expectedIDs)
        #expect(live.transcript.map(\.id) == expectedIDs)
        #expect(live.toolCards.isEmpty)
        #expect(after.toolCards.isEmpty)
        #expect(after.runs.map(\.id) == [runID, replacement.id])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentToolInvocation>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentToolResult>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentReviewRecord>()) == 0)
    }

    @Test
    func sameRunTruncationPreservesThePrefixAndAtomicallyAdoptsTheReplacement() async throws {
        let configuration = localModelConfiguration(
            "AgentSameRunTruncationTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let oldRunID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let replacementID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let realRunID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let instant = Date(timeIntervalSinceReferenceDate: 100)
        let prefixAttachment = AgentContextAttachment(
            kind: .file, label: "prefix.txt", contentTypeIdentifier: "public.plain-text",
            suggestedFilename: "prefix.txt", data: Data("prefix".utf8))
        let removedAttachment = AgentContextAttachment(
            kind: .file, label: "removed.txt", contentTypeIdentifier: "public.plain-text",
            suggestedFilename: "removed.txt", data: Data("removed".utf8))
        let replacementAttachment = AgentContextAttachment(
            kind: .file, label: "replacement.txt", contentTypeIdentifier: "public.plain-text",
            suggestedFilename: "replacement.txt", data: Data("replacement".utf8))
        let opening = AgentTranscriptMessage(
            role: .user, text: "Opening", authoredText: "Opening",
            contextAttachments: [prefixAttachment],
            contextSnapshot: .init(sessionContext: "prefix context"), createdAt: instant)
        let prefixCall = AgentToolCall(
            id: "prefix-call", name: "inspect", arguments: .object([:]))
        let prefixAssistant = AgentTranscriptMessage(
            role: .assistant, text: "Prefix", toolCalls: [prefixCall], createdAt: instant)
        let prefixResult = AgentTranscriptMessage(
            role: .tool, text: "prefix result", toolCallID: prefixCall.id,
            toolName: prefixCall.name, modelText: "prefix preview", createdAt: instant)
        let steering = AgentTranscriptMessage(
            role: .user, text: "Steer", authoredText: "Steer",
            contextAttachments: [removedAttachment],
            contextSnapshot: .init(sessionContext: "removed context"), createdAt: instant)
        let suffixAssistant = AgentTranscriptMessage(
            role: .assistant, text: "Suffix", createdAt: instant)
        let oldMessages = [
            opening, prefixAssistant, prefixResult, steering, suffixAssistant,
        ]
        let replacement = AgentTranscriptMessage(
            id: replacementID, role: .user, text: "Replacement", authoredText: "Replacement",
            contextAttachments: [replacementAttachment],
            contextSnapshot: .init(sessionContext: "replacement context"), createdAt: instant)
        let oldSummary = AgentRunSummary(
            id: oldRunID, state: .failed, startedAt: instant,
            finishedAt: instant, failure: "old failure")
        let live = ConversationModel(
            messages: [
                ChatMessage(id: opening.id, role: .user, text: opening.text, createdAt: instant),
                ChatMessage(
                    id: prefixAssistant.id, role: .assistant, text: prefixAssistant.text,
                    createdAt: instant),
                ChatMessage(id: steering.id, role: .user, text: steering.text, createdAt: instant),
                ChatMessage(
                    id: suffixAssistant.id, role: .assistant, text: suffixAssistant.text,
                    createdAt: instant),
            ], transcript: oldMessages, runState: .failed,
            messageRunIDs: Dictionary(uniqueKeysWithValues: oldMessages.map { ($0.id, oldRunID) }),
            runs: [oldSummary])
        #expect(live.editUserMessage(steering.id, replacement: replacement) != nil)
        let livePrefixFinishedAt = try #require(live.runSummaries[oldRunID]?.finishedAt)

        let oldSnapshot = AgentRunSnapshot(
            id: oldRunID, conversationID: conversationID, state: .failed,
            permissionMode: .askForApproval, messages: oldMessages,
            startedAt: instant, finishedAt: instant, failure: "old failure")
        try await repository.save(oldSnapshot)
        try await repository.setTitle("Preserved title", conversationID: conversationID)

        let descriptor = AgentToolDescriptor(
            name: "inspect", summary: "Inspect", inputSchema: .object([:]),
            target: .local, approvalPolicy: .approve)
        let prefixInvocation = AgentToolInvocation(
            runID: oldRunID, call: prefixCall, sourceMessageID: nil,
            createdAt: instant.addingTimeInterval(1))
        let review = GuardianDecision(
            verdict: .approve, risk: .low, userAuthorization: .high, reason: "Allowed")
        try await repository.record(.toolProposed(prefixInvocation, descriptor), runID: oldRunID)
        try await repository.record(
            .toolFinished(
                prefixInvocation,
                AgentToolResult(callID: prefixInvocation.call.id, content: "recorded result")),
            runID: oldRunID)
        let request = AgentApprovalRequest(
            invocation: prefixInvocation, descriptor: descriptor, userIntent: "Inspect")
        try await repository.record(.reviewFinished(request, review), runID: oldRunID)
        let nilBoundary = AgentCompactionRecord(
            compactedThroughMessageID: nil, sequence: 0, summary: "Legacy base",
            summarizedTokens: 4, keptTokens: 1, displayAnchor: instant)
        let keptCompaction = AgentCompactionRecord(
            compactedThroughMessageID: prefixResult.id, sequence: 1, summary: "Kept prefix",
            summarizedTokens: 8, keptTokens: 2, displayAnchor: instant)
        for record in [nilBoundary, keptCompaction] {
            try await repository.persistCompaction(record, conversationID: conversationID)
        }

        let preEditStore = AssistantConversationStore()
        preEditStore.restore(try await repository.loadConversations())
        let persistedLive = try #require(preEditStore.conversations.first)
        #expect(persistedLive.toolCards.map(\.invocation.id) == [prefixInvocation.id])
        let operations = AssistantConversationOperations(repository: repository)
        #expect(
            try await operations.edit(
                persistedLive, messageID: steering.id, replacement: replacement) != nil)
        #expect(persistedLive.toolCards.map(\.invocation.id) == [prefixInvocation.id])
        #expect(persistedLive.runSummaries[oldRunID]?.finishedAt == livePrefixFinishedAt)

        let staged = try #require(try await repository.loadConversations().first)
        #expect(staged.messages.map(\.id) == [opening.id, prefixAssistant.id, prefixResult.id, replacement.id])
        #expect(staged.compactions.map(\.id) == [nilBoundary.id, keptCompaction.id])
        #expect(staged.title == "Preserved title")
        #expect(staged.toolCards.map(\.invocation.id) == [prefixInvocation.id])
        #expect(staged.toolCards.first?.invocation.sourceMessageID == prefixAssistant.id)
        #expect(staged.runs.map(\.id) == [oldRunID, replacement.id])
        let stagedPrefix = try #require(staged.runs.first { $0.id == oldRunID })
        #expect(stagedPrefix.state == .completed)
        #expect(stagedPrefix.failure == nil)
        #expect(stagedPrefix.finishedAt == livePrefixFinishedAt)
        #expect(staged.messageRunIDs[opening.id] == oldRunID)
        #expect(staged.messageRunIDs[prefixResult.id] == oldRunID)
        #expect(staged.messageRunIDs[replacement.id] == replacement.id)

        let attachmentRows = try container.mainContext.fetch(
            FetchDescriptor<PersistentAgentContextAttachments>())
        let replayRows = try container.mainContext.fetch(
            FetchDescriptor<PersistentAgentMessageReplay>())
        #expect(Set(attachmentRows.map(\.messageID)) == [opening.id, replacement.id])
        #expect(Set(replayRows.map(\.messageID)) == [opening.id, prefixResult.id, replacement.id])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentToolInvocation>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentToolResult>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentReviewRecord>()) == 1)

        var realSnapshot = AgentRunSnapshot(
            id: realRunID, conversationID: conversationID, state: .running,
            permissionMode: .askForApproval,
            messages: [opening, prefixAssistant, prefixResult, replacement],
            startedAt: instant)
        try await repository.save(realSnapshot)
        let adopted = try #require(try await repository.loadConversations().first)
        #expect(adopted.runs.map(\.id) == [oldRunID, realRunID])
        #expect(try #require(adopted.runs.first { $0.id == realRunID }).startedAt > instant)
        realSnapshot.state = .completed
        realSnapshot.finishedAt = instant.addingTimeInterval(1)
        try await repository.save(realSnapshot)
        try await repository.save(oldSnapshot)
        let lateInvocation = AgentToolInvocation(
            runID: oldRunID,
            call: AgentToolCall(id: "late-call", name: "inspect", arguments: .object([:])),
            sourceMessageID: suffixAssistant.id, createdAt: instant)
        try await repository.record(.toolProposed(lateInvocation, descriptor), runID: oldRunID)

        let reopened = try #require(try await repository.loadConversations().first)
        #expect(reopened.messages.map(\.id) == [opening.id, prefixAssistant.id, prefixResult.id, replacement.id])
        #expect(reopened.messageRunIDs[replacement.id] == realRunID)
        #expect(reopened.runs.map(\.id) == [oldRunID, realRunID])
        #expect(reopened.runs.first { $0.id == oldRunID }?.finishedAt == livePrefixFinishedAt)
        #expect(reopened.lastRunState == .completed)
        #expect(try #require(reopened.runs.first { $0.id == realRunID }).startedAt > instant)
        #expect(reopened.toolCards.map(\.invocation.id) == [prefixInvocation.id])
        #expect(
            try container.mainContext.fetch(
                FetchDescriptor<PersistentAgentMessage>(
                    predicate: #Predicate { $0.id == replacementID }
                )
            ).first?.runID == realRunID)
        #expect(
            try container.mainContext.fetch(
                FetchDescriptor<PersistentAgentRun>(
                    predicate: #Predicate { $0.id == replacementID }
                )
            ).isEmpty)
    }

    @Test
    func editingALaterRunOpeningKeepsAnEarlierEmptyRunBeforeTheReplacement() async throws {
        let configuration = localModelConfiguration(
            "AgentEmptyPrefixRunTruncationTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let emptyRunID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE"))
        let targetRunID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let replacementID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let messageClock = Date(timeIntervalSinceReferenceDate: 100)
        let emptyRunClock = Date(timeIntervalSinceReferenceDate: 200)
        let targetRunClock = Date(timeIntervalSinceReferenceDate: 300)
        try await repository.save(
            AgentRunSnapshot(
                id: emptyRunID, conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval, messages: [],
                startedAt: emptyRunClock, finishedAt: emptyRunClock))
        let target = AgentTranscriptMessage(
            role: .user, text: "Later opening", authoredText: "Later opening",
            createdAt: messageClock)
        try await repository.save(
            AgentRunSnapshot(
                id: targetRunID, conversationID: conversationID, state: .failed,
                permissionMode: .askForApproval, messages: [target],
                startedAt: targetRunClock, finishedAt: targetRunClock, failure: "old failure"))
        let store = AssistantConversationStore()
        store.restore(try await repository.loadConversations())
        let conversation = try #require(store.conversations.first)
        let replacement = AgentTranscriptMessage(
            id: replacementID, role: .user, text: "Replacement", authoredText: "Replacement",
            createdAt: messageClock)

        let operations = AssistantConversationOperations(repository: repository)
        #expect(
            try await operations.edit(
                conversation, messageID: target.id, replacement: replacement) != nil)

        let liveStaging = try #require(conversation.runSummaries[replacement.id])
        #expect(liveStaging.startedAt > emptyRunClock)
        #expect(
            conversation.runSummaries.values.sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }.map(\.id) == [emptyRunID, replacement.id])
        let reopened = try #require(try await repository.loadConversations().first)
        #expect(reopened.runs.map(\.id) == [emptyRunID, replacement.id])
        #expect(reopened.runs.last?.startedAt == liveStaging.startedAt)
        #expect(reopened.messages.map(\.id) == [replacement.id])
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
        try await repository.save(
            AgentRunSnapshot(
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
        let forkCompaction = AgentCompactionRecord(
            compactedThroughMessageID: nil, sequence: 0, summary: "Fork base",
            summarizedTokens: 10, keptTokens: 2, displayAnchor: .now
        )
        try await repository.save(
            AgentRunSnapshot(
                conversationID: originalID, state: .completed,
                permissionMode: .askForApproval,
                messages: [
                    AgentTranscriptMessage(
                        id: originalMessageID, role: .user, text: "Original", authoredText: "Original"
                    )
                ]
            ))
        try await repository.createConversation(
            StoredAgentConversation(
                id: forkID,
                messages: [
                    AgentTranscriptMessage(
                        id: forkMessageID, role: .user, text: "Original", authoredText: "Original"
                    )
                ], compactions: [forkCompaction], lastRunState: .completed,
                metadata: StoredAgentConversationMetadata(customTitle: "Original (1)")
            ))

        let restored = try await repository.loadConversations()
        #expect(Set(restored.map(\.id)) == Set([originalID, forkID]))
        #expect(restored.first { $0.id == forkID }?.messages.first?.id == forkMessageID)
        #expect(
            restored.first { $0.id == forkID }?.modelTranscript?.first?.id
                == forkCompaction.summaryMessageID)
        #expect(restored.first { $0.id == forkID }?.metadata.customTitle == "Original (1)")

        try await repository.deleteConversation(originalID)
        #expect(try await repository.loadConversations().map(\.id) == [forkID])
        try await repository.deleteConversation(forkID)
        #expect(
            try container.mainContext.fetch(
                FetchDescriptor<PersistentAgentCompaction>()
            ).isEmpty)
    }

    @Test
    func compactionPersistsImmediatelyWithoutReplacingDisplayHistory() async throws {
        let configuration = localModelConfiguration(
            "AgentCompactionPersistenceTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let conversationID = UUID()
        let old = AgentTranscriptMessage(
            role: .user, text: "Old question " + String(repeating: "x", count: 4_000)
        )
        let answer = AgentTranscriptMessage(
            role: .assistant, text: "Old answer " + String(repeating: "y", count: 4_000)
        )
        let recent = AgentTranscriptMessage(role: .user, text: "Recent question")
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        try await repository.save(
            AgentRunSnapshot(
                conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval, messages: [old, answer, recent]
            ))
        let record = AgentCompactionRecord(
            compactedThroughMessageID: answer.id, sequence: 0,
            summary: "## Goal\nKeep the recent work",
            summarizedTokens: 20, keptTokens: 8,
            displayAnchor: answer.createdAt
        )

        try await repository.persistCompaction(record, conversationID: conversationID)

        let reopened = SwiftDataAgentRunRepository(context: container.mainContext)
        let restored = try #require(try await reopened.loadConversations().first)
        #expect(restored.messages.map(\.id) == [old.id, answer.id, recent.id])
        #expect(restored.modelTranscript?.map(\.id) == [record.summaryMessageID, recent.id])
        #expect(restored.modelTranscript?.first?.isCompaction == true)
        #expect(restored.compactions == [record])
        let store = AssistantConversationStore()
        store.restore([restored])
        let live = try #require(store.conversation(id: conversationID))
        #expect(live.messages.map(\.id) == [old.id, answer.id, recent.id])
        #expect(live.transcript.map(\.id) == [record.summaryMessageID, recent.id])
        #expect(live.compactions.map(\.id) == [record.id])
        let fullContext = ConversationModel(transcript: restored.messages).contextEstimate.total
        #expect(live.contextEstimate.total < fullContext)
        #expect(
            try container.mainContext.fetch(
                FetchDescriptor<PersistentAgentCompaction>()
            ).count == 1)
    }

    @Test
    func aRunAfterCompactionDoesNotPersistTheSyntheticSummaryAsAMessage() async throws {
        let configuration = localModelConfiguration(
            "AgentCompactionNextRunTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let conversationID = UUID()
        let old = AgentTranscriptMessage(role: .user, text: "Old")
        let recent = AgentTranscriptMessage(role: .assistant, text: "Recent")
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        try await repository.save(
            AgentRunSnapshot(
                conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval, messages: [old, recent]
            ))
        let record = AgentCompactionRecord(
            compactedThroughMessageID: old.id, sequence: 0, summary: "Summary",
            summarizedTokens: 10, keptTokens: 2, displayAnchor: old.createdAt
        )
        try await repository.persistCompaction(record, conversationID: conversationID)
        let followUp = AgentTranscriptMessage(role: .user, text: "Continue")
        try await repository.save(
            AgentRunSnapshot(
                conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval,
                messages: [record.summaryMessage, recent, followUp]
            ))

        let messageRows = try container.mainContext.fetch(
            FetchDescriptor<PersistentAgentMessage>()
        )
        let compactionMessageCount = messageRows.filter { $0.isCompaction }.count
        #expect(compactionMessageCount == 0)
        #expect(!messageRows.contains { $0.id == record.summaryMessageID })
        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.map(\.id) == [old.id, recent.id, followUp.id])
        #expect(
            restored.modelTranscript?.map(\.id) == [
                record.summaryMessageID, recent.id, followUp.id,
            ])
    }

    @Test
    func newestOfTwoCompactionsWinsAfterRestore() async throws {
        let configuration = localModelConfiguration(
            "AgentRepeatedCompactionTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let conversationID = UUID()
        let messages = [
            AgentTranscriptMessage(role: .user, text: "One"),
            AgentTranscriptMessage(role: .assistant, text: "Two"),
            AgentTranscriptMessage(role: .user, text: "Three"),
            AgentTranscriptMessage(role: .assistant, text: "Four"),
        ]
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        try await repository.save(
            AgentRunSnapshot(
                conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval, messages: messages
            ))
        let first = AgentCompactionRecord(
            compactedThroughMessageID: messages[1].id, sequence: 0, summary: "First",
            summarizedTokens: 10, keptTokens: 2, displayAnchor: messages[1].createdAt,
            compactedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let second = AgentCompactionRecord(
            compactedThroughMessageID: messages[2].id, sequence: 1, summary: "Second",
            summarizedTokens: 12, keptTokens: 2, displayAnchor: messages[2].createdAt,
            compactedAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        try await repository.persistCompaction(first, conversationID: conversationID)
        try await repository.persistCompaction(second, conversationID: conversationID)

        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.map(\.id) == messages.map(\.id))
        #expect(restored.modelTranscript?.map(\.id) == [second.summaryMessageID, messages[3].id])
        #expect(restored.compactions == [first, second])
    }

    @Test
    func truncationDeletesOnlyCompactionsWhoseBoundaryWasRemoved() async throws {
        let configuration = localModelConfiguration(
            "AgentCompactionTruncationTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let conversationID = UUID()
        let firstUser = AgentTranscriptMessage(role: .user, text: "One")
        let firstAnswer = AgentTranscriptMessage(role: .assistant, text: "Answer one")
        let secondUser = AgentTranscriptMessage(role: .user, text: "Two")
        var firstRun = AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval, messages: [firstUser, firstAnswer],
            startedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        firstRun.finishedAt = Date(timeIntervalSinceReferenceDate: 2)
        var secondRun = AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval,
            messages: [firstUser, firstAnswer, secondUser],
            startedAt: Date(timeIntervalSinceReferenceDate: 3)
        )
        secondRun.finishedAt = Date(timeIntervalSinceReferenceDate: 4)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        try await repository.save(firstRun)
        try await repository.save(secondRun)
        let kept = AgentCompactionRecord(
            compactedThroughMessageID: firstAnswer.id, sequence: 0, summary: "Kept",
            summarizedTokens: 8, keptTokens: 2, displayAnchor: firstAnswer.createdAt
        )
        let removed = AgentCompactionRecord(
            compactedThroughMessageID: secondUser.id, sequence: 1, summary: "Removed",
            summarizedTokens: 10, keptTokens: 2, displayAnchor: secondUser.createdAt
        )
        try await repository.persistCompaction(kept, conversationID: conversationID)
        try await repository.persistCompaction(removed, conversationID: conversationID)

        try await repository.truncateConversation(
            conversationID, fromUserMessageID: secondUser.id,
            replacingWith: AgentTranscriptMessage(role: .user, text: "Edited")
        )

        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.compactions == [kept])
        #expect(restored.modelTranscript?.first?.id == kept.summaryMessageID)
    }
}
