import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
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
        snapshot.startedAt = snapshot.startedAt.addingTimeInterval(1)
        snapshot.finishedAt = snapshot.startedAt
        let continued = AgentTranscriptMessage(
            role: .user, text: "continue", authoredText: "continue",
            contextSnapshot: .init(sessionContext: "host B"))
        snapshot.messages.append(continued)
        try await repository.save(snapshot)
        let restored = try #require(try await repository.loadConversations().first)
        #expect(restored.messages.first?.contextSnapshot == first.contextSnapshot)
        #expect(restored.messages.first?.text == "inspect")
        #expect(restored.messages.first { $0.role == .tool }?.modelText == "fixed preview")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentAgentMessageReplay>()) == 3)
        let model = ConversationModel(messages: [], transcript: restored.messages)
        #expect(model.editedUserMessage(first.id, authoredText: "edited") == nil)
        let editable = try #require(
            model.editedUserMessage(continued.id, authoredText: "edited"))
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
        let conversation = try #require(try await repository.loadConversations().first)
        let restored = try #require(conversation.messages.last)
        let resultID = AgentTranscriptMessage.toolResultID(runID: snapshot.id, callID: call.id)
        #expect(restored.modelText == "frozen preview")
        #expect(restored.id == resultID)
        #expect(conversation.messageRunIDs[resultID] == snapshot.id)
    }

    @Test(arguments: [AgentRunState.failed, .interrupted])
    func aRealRunAtomicallyAdoptsTheEditedStagingMessageAndReplayBacking(
        state: AgentRunState
    ) async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let original = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let originalRun = AgentRunSnapshot(
            conversationID: conversationID, state: .completed,
            permissionMode: .askForApproval, messages: [original])
        try await repository.save(originalRun)
        let replacement = AgentTranscriptMessage(
            role: .user, text: "after", authoredText: "after",
            contextSnapshot: .init(sessionContext: "captured host"))
        try await repository.truncateConversation(
            conversationID, fromUserMessageID: original.id, replacingWith: replacement)

        let realRun = AgentRunSnapshot(
            conversationID: conversationID, state: state,
            permissionMode: .askForApproval, messages: [replacement],
            failure: state == .failed ? "preparation failed" : nil)
        try await repository.save(realRun)

        let messageRows = try container.mainContext.fetch(FetchDescriptor<PersistentAgentMessage>())
        let runRows = try container.mainContext.fetch(FetchDescriptor<PersistentAgentRun>())
        let replayRows = try container.mainContext.fetch(FetchDescriptor<PersistentAgentMessageReplay>())
        #expect(messageRows.count == 1)
        #expect(messageRows.first?.id == replacement.id)
        #expect(messageRows.first?.runID == realRun.id)
        #expect(runRows.map(\.id) == [realRun.id])
        #expect(replayRows.map(\.messageID) == [replacement.id])

        let freshRepository = SwiftDataAgentRunRepository(context: ModelContext(container))
        let restored = try #require(try await freshRepository.loadConversations().first)
        #expect(restored.messages.map(\.id) == [replacement.id])
        #expect(restored.messages.first?.contextSnapshot == replacement.contextSnapshot)
        #expect(restored.messageRunIDs[replacement.id] == realRun.id)
        #expect(restored.runs.map(\.id) == [realRun.id])
        #expect(restored.runs.first?.state == state)
        #expect(restored.runs.first?.failure == (state == .failed ? "preparation failed" : nil))
    }

    @Test
    func queuedCancellationAtomicallyAdoptsEditedStagingAndReloadsCapturedPayload() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let original = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        try await repository.save(
            AgentRunSnapshot(
                conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval, messages: [original]
            ))
        let stored = try #require(try await repository.loadConversations().first)
        let store = AssistantConversationStore()
        store.restore([stored])
        let conversation = try #require(store.conversations.first)
        let context = AgentTurnContextSnapshot(
            sessionContext: "captured host", skillCatalog: "captured skills",
            planContract: "captured plan", toolAvailability: ["terminal_suggest": false]
        )
        let image = AgentImageAttachment(
            label: "capture.png", mimeType: "image/png", data: Data([1, 2, 3]),
            pixelWidth: 2, pixelHeight: 2
        )
        let attachment = AgentContextAttachment(
            id: UUID(), kind: .file, label: "capture.txt",
            contentTypeIdentifier: "public.plain-text", suggestedFilename: "capture.txt",
            data: Data("captured payload".utf8)
        )
        let replacement = AgentTranscriptMessage(
            role: .user, text: "after", authoredText: "After authored",
            images: [image], contextAttachments: [attachment], contextSnapshot: context,
            createdAt: .now
        )
        let operations = AssistantConversationOperations(repository: repository)
        let composed = try #require(
            try await operations.edit(
                conversation, messageID: original.id, replacement: replacement
            ))
        let staging = try #require(conversation.runSummaries[replacement.id])
        let calls = ReplayModelCalls()
        conversation.start(
            runtime: AgentRuntime(
                model: CountingReplayModel(calls: calls), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, promptID: composed.id,
                prompt: composed.text, authoredPrompt: composed.authoredText,
                promptImages: composed.images,
                promptContextAttachments: composed.contextAttachments,
                permissionMode: .fullAccess, contextSnapshot: context
            ),
            repository: repository
        )

        await conversation.stopAndWait()

        #expect(await calls.count == 0)
        #expect(conversation.runSummaries[replacement.id] == nil)
        let freshRepository = SwiftDataAgentRunRepository(context: ModelContext(container))
        let restored = try #require(try await freshRepository.loadConversations().first)
        let run = try #require(restored.runs.first)
        #expect(restored.runs.count == 1)
        #expect(run.id != replacement.id)
        #expect(run.state == .cancelled)
        #expect(run.startedAt >= staging.startedAt)
        #expect(run.finishedAt.map { $0 >= run.startedAt } == true)
        #expect(restored.messageRunIDs[replacement.id] == run.id)
        let message = try #require(restored.messages.first)
        #expect(message.id == replacement.id)
        #expect(message.text == replacement.text)
        #expect(message.authoredText == replacement.authoredText)
        #expect(message.images == [image])
        #expect(message.contextAttachments == [attachment])
        #expect(message.contextSnapshot == context)
        #expect(message.createdAt <= (run.finishedAt ?? .distantPast))
        let runRows = try ModelContext(container).fetch(FetchDescriptor<PersistentAgentRun>())
        #expect(runRows.count == 1)
        #expect(runRows.first?.permissionMode == AgentPermissionMode.fullAccess.rawValue)
    }

    @Test
    func capturedConfigurationFailureAdoptsEditedStagingOnlyAfterDurableSave() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let conversationID = UUID()
        let image = AgentImageAttachment(
            label: "capture.png", mimeType: "image/png", data: Data([4, 5, 6]),
            pixelWidth: 2, pixelHeight: 2
        )
        let attachment = AgentContextAttachment(
            id: UUID(), kind: .file, label: "capture.txt",
            contentTypeIdentifier: "public.plain-text", suggestedFilename: "capture.txt",
            data: Data("captured payload".utf8)
        )
        let original = AgentTranscriptMessage(
            role: .user, text: "before", authoredText: "before",
            images: [image], contextAttachments: [attachment]
        )
        try await repository.save(
            AgentRunSnapshot(
                conversationID: conversationID, state: .completed,
                permissionMode: .askForApproval, messages: [original]
            ))
        let stored = try #require(try await repository.loadConversations().first)
        let store = AssistantConversationStore()
        store.restore([stored])
        let conversation = try #require(store.conversations.first)
        conversation.permissionMode = .fullAccess
        let controller = AssistantExecutionController(
            ai: AIConfigurationModel(), skills: SkillLibraryModel(), repository: repository,
            authorize: { true },
            makeRegistry: { _, _, _, _, _, _, _ in AgentToolRegistry([]) },
            title: { _ in "Title" }
        )
        let operations = AssistantConversationOperations(repository: repository)
        let prepared = try #require(
            controller.prepareAgentEdit(
                conversation, messageID: original.id, text: "after",
                context: SessionContext(hostName: "captured-host", workingDirectory: "/captured"),
                terminalSuggestionsAvailable: true
            ))

        #expect(try await controller.performAgentEdit(prepared, in: conversation, operations: operations))
        let replacement = try #require(conversation.transcript.first)
        let staging = try #require(conversation.runSummaries[replacement.id])
        await conversation.stopAndWait()

        #expect(conversation.runState == .failed)
        #expect(conversation.runSummaries[replacement.id] == nil)

        let freshRepository = SwiftDataAgentRunRepository(context: ModelContext(container))
        let restored = try #require(try await freshRepository.loadConversations().first)
        let run = try #require(restored.runs.first)
        let message = try #require(restored.messages.first)
        #expect(restored.runs.count == 1)
        #expect(run.id != replacement.id)
        #expect(run.state == .failed)
        #expect(run.failure == String(localized: "No Chat model is configured."))
        #expect(run.startedAt >= staging.startedAt)
        #expect(run.finishedAt.map { $0 >= run.startedAt } == true)
        #expect(restored.messageRunIDs[replacement.id] == run.id)
        #expect(message.id == replacement.id)
        #expect(message.text == replacement.text)
        #expect(message.authoredText == "after")
        #expect(message.images == [image])
        #expect(message.contextAttachments == [attachment])
        #expect(message.contextSnapshot?.sessionContext?.contains("captured-host") == true)
        #expect(message.contextSnapshot?.toolAvailability?["terminal_suggest"] == true)
        #expect(message.createdAt <= (run.finishedAt ?? .distantPast))
        let runRows = try ModelContext(container).fetch(FetchDescriptor<PersistentAgentRun>())
        #expect(runRows.count == 1)
        #expect(runRows.first?.permissionMode == AgentPermissionMode.fullAccess.rawValue)
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

private actor ReplayModelCalls {
    private(set) var count = 0
    func called() { count += 1 }
}

private struct CountingReplayModel: AgentModelStreaming {
    let calls: ReplayModelCalls

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.called()
                continuation.yield(.finished(.completed))
                continuation.finish()
            }
        }
    }
}
