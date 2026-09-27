import AgentKit
import Foundation
import TermindDomain
import Testing

@testable import TermindApplication

@Suite @MainActor
struct AssistantExecutionControllerTests {
    @Test
    func captureFreezesTurnContextAndConfigurationAcrossMemoryPreparation() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository()
        let oldSkill = AgentSkill(name: "old-skill", summary: "Old procedure", body: "Do the old procedure")
        let skills = SkillLibraryModel(skills: [oldSkill])
        let (ai, provider) = configuredAI(secret: "captured-secret")
        let registryCapture = RegistryCapture()
        let controller = makeController(
            ai: ai, skills: skills, repository: repository, memory: memory,
            makeRegistry: { _, model, provider, catalog, _, _, _ in
                registryCapture.record(model: model, provider: provider, catalog: catalog)
                return AgentToolRegistry([])
            })
        let conversation = ConversationModel()
        conversation.permissionMode = .askForApproval
        conversation.reasoningEffort = .low
        conversation.isPlanning = true
        conversation.composer.draft = "inspect"

        #expect(
            controller.sendAgentDraft(
                conversation,
                context: SessionContext(hostName: "captured-host", workingDirectory: "/captured"),
                terminalSuggestionsAvailable: true))
        await memoryStore.waitUntilPreparationEntered()

        conversation.permissionMode = .fullAccess
        conversation.reasoningEffort = .high
        conversation.isPlanning = false
        skills.setEnabled(false, for: oldSkill.id)
        skills.upsert(AgentSkill(name: "new-skill", summary: "New procedure", body: "Do the new procedure"))
        ai.setSecret(nil, for: provider.credentialRef)
        ai.setWebSearch(.init(isEnabled: false, prefersBuiltIn: false))

        let captured = try #require(conversation.transcript.last?.contextSnapshot)
        #expect(captured.sessionContext?.contains("captured-host") == true)
        #expect(captured.planContract == TermindAgentPolicy.planContract)
        #expect(captured.toolAvailability?["terminal_suggest"] == true)
        #expect(captured.skillCatalog?.contains("old-skill") == true)
        #expect(captured.skillCatalog?.contains("new-skill") != true)
        #expect(registryCapture.modelID == provider.models[0].id)
        #expect(registryCapture.providerID == provider.id)
        #expect(registryCapture.catalog?.catalogBlock.contains("old-skill") == true)

        conversation.stop()
        await memoryStore.releasePreparation()
        try await waitUntil { !conversation.isPreparingAgentRun }
        #expect(conversation.runState == .interrupted)
        let interrupted = try #require(await repository.snapshots.last)
        #expect(interrupted.state == .interrupted)
        #expect(interrupted.permissionMode == .askForApproval)
    }

    @Test
    func credentialAddedAfterCaptureDoesNotReviveTheTurn() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository()
        let (ai, provider) = configuredAI(secret: nil)
        let controller = makeController(ai: ai, repository: repository, memory: memory)
        let conversation = ConversationModel()
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        await memoryStore.waitUntilPreparationEntered()
        ai.setSecret("late-secret", for: provider.credentialRef)
        await memoryStore.releasePreparation()

        try await waitUntil { !conversation.isPreparingAgentRun }
        #expect(conversation.runState == .failed)
        await repository.waitUntilSnapshot(state: .failed)
        #expect(await repository.snapshots.last?.state == .failed)
    }

    @Test
    func missingModelFailureStaysOwnedUntilSaveAndAllCancellationPathsJoinIt() async throws {
        let repository = RecordingAgentRunRepository(blocksFirstSave: true)
        let controller = makeController(repository: repository)
        let conversation = ConversationModel()
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        await repository.waitUntilSaveEntered()

        #expect(conversation.isPreparingAgentRun)
        #expect(conversation.isPersistingAgentPreparationFailure)
        #expect(conversation.runState != .failed)
        #expect(conversation.runSummaries.isEmpty)

        conversation.stop()
        let probe = JoinProbe(expectedStarts: 2)
        let joinedStop = Task { @MainActor in
            probe.started()
            await conversation.stopAndWait()
            probe.completed()
        }
        let joinedControllerCancellation = Task { @MainActor in
            probe.started()
            await controller.cancelPendingRuns().value
            probe.completed()
        }
        try await waitUntil { probe.startedCount == probe.expectedStarts }

        #expect(conversation.isPreparingAgentRun)
        #expect(await repository.snapshots.map(\.state) == [.failed])
        #expect(await repository.completedSnapshots.isEmpty)
        #expect(probe.completedCount == 0)

        await repository.releaseSave()
        await joinedStop.value
        await joinedControllerCancellation.value

        #expect(!conversation.isPreparingAgentRun)
        #expect(!conversation.isPersistingAgentPreparationFailure)
        #expect(conversation.runState == .failed)
        #expect(await repository.snapshots.map(\.state) == [.failed])
        #expect(await repository.completedSnapshots.map(\.state) == [.failed])
        #expect(probe.completedCount == 2)
    }

    @Test
    func capturedFailureSaveOutlivesReleasedControllerAndConversationHandles() async throws {
        let repository = RecordingAgentRunRepository(blocksFirstSave: true)
        var controller: AssistantExecutionController? = makeController(repository: repository)
        var conversation: ConversationModel? = ConversationModel()
        conversation?.composer.draft = "persist me"
        let releasedController = WeakReference(controller)
        let releasedConversation = WeakReference(conversation)

        #expect(controller?.sendAgentDraft(try #require(conversation)) == true)
        await repository.waitUntilSaveEntered()
        controller = nil
        conversation = nil

        #expect(releasedController.value != nil)
        #expect(releasedConversation.value != nil)

        await repository.releaseSave()
        await repository.waitUntilSaveCompleted()
        try await waitUntil {
            releasedController.value == nil && releasedConversation.value == nil
        }
        #expect(await repository.completedSnapshots.map(\.state) == [.failed])
    }

    @Test
    func missingCredentialAfterMemoryPreparationProjectsOnlyAfterSaveCompletes() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository(blocksFirstSave: true)
        let (ai, _) = configuredAI(secret: nil)
        let controller = makeController(ai: ai, repository: repository, memory: memory)
        let conversation = ConversationModel()
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        await memoryStore.waitUntilPreparationEntered()
        await memoryStore.releasePreparation()
        await repository.waitUntilSaveEntered()

        #expect(conversation.isPreparingAgentRun)
        #expect(conversation.isPersistingAgentPreparationFailure)
        #expect(conversation.runState != .failed)

        await repository.releaseSave()
        try await waitUntil { !conversation.isPreparingAgentRun }

        #expect(conversation.runState == .failed)
        #expect(await repository.completedSnapshots.map(\.state) == [.failed])
    }

    @Test
    func archiveAndDeleteWaitForCapturedFailurePersistence() async throws {
        do {
            let repository = RecordingAgentRunRepository(blocksFirstSave: true)
            let controller = makeController(repository: repository)
            let operations = AssistantConversationOperations(repository: repository)
            let conversation = ConversationModel()
            conversation.composer.draft = "archive me"

            #expect(controller.sendAgentDraft(conversation))
            await repository.waitUntilSaveEntered()
            let archive = Task {
                try await operations.setArchived(true, conversation: conversation)
            }
            await Task.yield()

            #expect(await repository.metadataMutationCount == 0)
            #expect(conversation.archivedAt == nil)

            await repository.releaseSave()
            try await archive.value
            #expect(await repository.metadataMutationCount == 1)
            #expect(await repository.events == ["save-attempt", "save-completed", "metadata"])
            #expect(conversation.archivedAt != nil)
        }

        do {
            let repository = RecordingAgentRunRepository(blocksFirstSave: true)
            let controller = makeController(repository: repository)
            let operations = AssistantConversationOperations(repository: repository)
            let conversation = ConversationModel()
            conversation.composer.draft = "delete me"

            #expect(controller.sendAgentDraft(conversation))
            await repository.waitUntilSaveEntered()
            let deletion = Task { try await operations.delete(conversation) }
            await Task.yield()

            #expect(await repository.deletionCount == 0)

            await repository.releaseSave()
            #expect(try await deletion.value.deleted)
            #expect(await repository.deletionCount == 1)
            #expect(await repository.events == ["save-attempt", "save-completed", "delete"])
        }
    }

    @Test
    func immediateStopInvalidatesPreparationBeforeTheMemoryBarrierIsReleased() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository()
        let (ai, _) = configuredAI(secret: nil)
        let controller = makeController(ai: ai, repository: repository, memory: memory)
        let conversation = ConversationModel()
        conversation.permissionMode = .askForApproval
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        await memoryStore.waitUntilPreparationEntered()
        conversation.permissionMode = .fullAccess
        conversation.stop()
        conversation.stop()

        await memoryStore.releasePreparation()
        try await waitUntil { !conversation.isPreparingAgentRun }
        #expect(conversation.runState == .interrupted)
        #expect(!conversation.isStreaming)
        let snapshots = await repository.snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots[0].state == .interrupted)
        #expect(snapshots[0].permissionMode == .askForApproval)
    }

    @Test
    func globalCancellationInterruptsAPreparedEditThatHasNoPreparationTask() async throws {
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])

        #expect(controller.prepareAgentEdit(conversation, messageID: message.id, text: "after") != nil)
        #expect(conversation.isPreparingAgentRun)
        await controller.cancelPendingRuns().value

        #expect(!conversation.isPreparingAgentRun)
        #expect(conversation.transcript == [message])
        #expect(conversation.runState == .interrupted)
        #expect(await repository.snapshots.last?.state == .interrupted)
    }

    @Test
    func cancelledPreparedEditCannotEnterHistoryMutation() async throws {
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])
        let prepared = try #require(
            controller.prepareAgentEdit(conversation, messageID: message.id, text: "after"))

        await controller.cancelPendingRuns().value

        #expect(
            try await !controller.performAgentEdit(
                prepared, in: conversation, operations: operations))
        #expect(await repository.truncationReplacement == nil)
        #expect(conversation.transcript == [message])
    }

    @Test
    func supersededPreparedEditCannotEnterHistoryMutation() async throws {
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])
        let stale = try #require(
            controller.prepareAgentEdit(conversation, messageID: message.id, text: "stale"))
        #expect(controller.prepareAgentEdit(conversation, messageID: message.id, text: "current") != nil)

        #expect(
            try await !controller.performAgentEdit(
                stale, in: conversation, operations: operations))
        #expect(await repository.truncationReplacement == nil)
        #expect(conversation.transcript == [message])

        await controller.cancelPendingRuns().value
    }

    @Test
    func cancellationDuringEditJoinsHistoryWorkBeforeRecordingInterruption() async throws {
        let repository = RecordingAgentRunRepository(blocksTruncation: true)
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])
        let prepared = try #require(
            controller.prepareAgentEdit(conversation, messageID: message.id, text: "after"))
        let edit = Task {
            try await controller.performAgentEdit(
                prepared, in: conversation, operations: operations)
        }

        await repository.waitUntilTruncationEntered()
        let cancellation = controller.cancelPendingRuns()
        await Task.yield()

        #expect(await repository.snapshots.isEmpty)
        #expect(conversation.isPreparingAgentRun)
        await repository.releaseTruncation()

        #expect(try await !edit.value)
        await cancellation.value
        #expect(await repository.truncationReplacement == nil)
        #expect(await repository.snapshots.map(\.state) == [.interrupted])
        #expect(conversation.transcript == [message])
        #expect(conversation.runState == .interrupted)
        #expect(!conversation.isPreparingAgentRun)
        #expect(!conversation.isStreaming)
    }

    @Test
    func supersededPreparationIgnoresAnOlderCancellationCompletion() async throws {
        let repository = RecordingAgentRunRepository(blocksFirstSave: true)
        let controller = makeController(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])

        #expect(controller.prepareAgentEdit(conversation, messageID: message.id, text: "first") != nil)
        let oldCancellation = controller.cancelPendingRuns()
        await repository.waitUntilSaveEntered()
        #expect(controller.prepareAgentEdit(conversation, messageID: message.id, text: "second") != nil)

        await repository.releaseSave()
        await oldCancellation.value

        #expect(conversation.isPreparingAgentRun)
        #expect(conversation.runState != .interrupted)

        await controller.cancelPendingRuns().value
        #expect(!conversation.isPreparingAgentRun)
    }

    @Test
    func selectingAnotherConversationDoesNotCancelPreparation() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository, memory: memory)
        let preparing = ConversationModel()
        preparing.composer.draft = "inspect"
        let visible = ConversationModel()
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(conversations: [preparing, visible]))

        #expect(controller.sendAgentDraft(preparing))
        await memoryStore.waitUntilPreparationEntered()
        library.select(visible.id)
        #expect(library.selectedConversation === visible)
        #expect(preparing.isPreparingAgentRun)

        await memoryStore.releasePreparation()
        try await waitUntil { !preparing.isPreparingAgentRun }
        #expect(preparing.runState == .failed)
        await repository.waitUntilSnapshot(state: .failed)
        #expect(await repository.snapshots.last?.state == .failed)
    }

    @Test
    func firstSendGuardsDoNotPromoteOrConsumeTheDraftConversation() {
        let library = AssistantLibraryModel()
        let unauthorized = makeController(authorize: { false })
        library.draftConversation.composer.draft = "keep"
        #expect(unauthorized.sendDraftConversation(in: library) == nil)
        #expect(library.conversations.isEmpty)
        #expect(library.draftConversation.composer.draft == "keep")

        let authorized = makeController()
        library.draftConversation.composer.draft = "   "
        #expect(authorized.sendDraftConversation(in: library) == nil)
        #expect(library.conversations.isEmpty)

        library.draftConversation.composer.draft = "wait for attachment"
        let pending = library.draftConversation.beginAttachmentImport(label: "notes.txt")
        #expect(pending != nil)
        #expect(authorized.sendDraftConversation(in: library) == nil)
        #expect(library.conversations.isEmpty)
        #expect(library.draftConversation.composer.draft == "wait for attachment")
        #expect(library.draftConversation.composer.pendingAttachments.count == 1)
    }

    @Test
    func firstSendCapturesAttachmentsAndArmedSkillExactlyOnce() throws {
        let library = AssistantLibraryModel()
        let controller = makeController()
        let conversation = library.draftConversation
        conversation.composer.draft = "inspect"
        conversation.composer.armedSkillName = "disk-triage"
        conversation.attach(ContextChip(kind: .file, label: "notes.txt", content: "captured body"))

        #expect(controller.sendDraftConversation(in: library) === conversation)
        #expect(library.conversations.map(\.id) == [conversation.id])
        #expect(library.draftConversation !== conversation)
        #expect(conversation.composer.attachments.isEmpty)
        #expect(conversation.composer.armedSkillName == nil)
        let turn = try #require(conversation.transcript.first)
        #expect(turn.authoredText == "inspect")
        #expect(turn.contextAttachments.map(\.label) == ["notes.txt"])
        #expect(turn.text.components(separatedBy: "<use_skill name=\"disk-triage\">").count == 2)
        #expect(turn.text.components(separatedBy: "captured body").count == 2)
    }

    @Test
    func textSendCapturesComposerPayloadsInsteadOfConsumingThemInvisibly() throws {
        let controller = makeController()
        let conversation = ConversationModel()
        let image = AgentImageAttachment(
            label: "graph.png", mimeType: "image/png", data: Data([7, 8, 9]),
            pixelWidth: 20, pixelHeight: 20)
        conversation.composer.draft = "keep this draft"
        conversation.composer.armedSkillName = "disk-triage"
        conversation.attach(ContextChip(kind: .file, label: "notes.txt", content: "captured body"))
        conversation.attach(ContextChip(kind: .image, label: image.label, image: image))

        #expect(controller.sendAgentText("Implement the fix.", in: conversation))

        let turn = try #require(conversation.transcript.first)
        #expect(turn.authoredText == "Implement the fix.")
        #expect(turn.text.contains("captured body"))
        #expect(turn.text.contains("<use_skill name=\"disk-triage\">"))
        #expect(turn.images == [image])
        #expect(turn.contextAttachments.map(\.label) == ["notes.txt"])
        #expect(conversation.composer.attachments.isEmpty)
        #expect(conversation.composer.armedSkillName == nil)
        #expect(conversation.composer.draft == "keep this draft")
    }

    @Test
    func planImplementationAtomicallyCapturesActingModeAndComposerPayloads() throws {
        let controller = makeController()
        let conversation = ConversationModel()
        let plan = AgentPlan(
            title: "Implementation plan", body: "Apply the requested change.",
            scratchPath: "/tmp/plan.md")
        conversation.isPlanning = true
        conversation.handle(.planPresented(plan))
        conversation.composer.armedSkillName = "disk-triage"
        conversation.attach(ContextChip(kind: .file, label: "notes.txt", content: "captured body"))
        let card = try #require(conversation.plans.first)

        #expect(controller.sendPlanImplementation(card, in: conversation))

        #expect(conversation.plans.first?.outcome == .implemented)
        #expect(!conversation.isPlanning)
        let turn = try #require(conversation.transcript.last)
        #expect(turn.authoredText == ConversationModel.implementationPrompt(for: plan))
        #expect(turn.contextSnapshot?.planContract == nil)
        #expect(turn.text.contains("captured body"))
        #expect(turn.text.contains("<use_skill name=\"disk-triage\">"))
        #expect(conversation.composer.attachments.isEmpty)
        #expect(conversation.composer.armedSkillName == nil)
    }

    @Test
    func refusedPlanImplementationPreservesPlanModeAndComposerPayloads() throws {
        let controller = makeController(authorize: { false })
        let conversation = ConversationModel()
        let plan = AgentPlan(
            title: "Implementation plan", body: "Apply the requested change.",
            scratchPath: "/tmp/plan.md")
        conversation.isPlanning = true
        conversation.handle(.planPresented(plan))
        conversation.composer.armedSkillName = "disk-triage"
        conversation.attach(ContextChip(kind: .file, label: "notes.txt", content: "keep me"))
        let card = try #require(conversation.plans.first)

        #expect(!controller.sendPlanImplementation(card, in: conversation))

        #expect(conversation.plans.first?.outcome == .pending)
        #expect(conversation.isPlanning)
        #expect(conversation.transcript.isEmpty)
        #expect(conversation.composer.attachments.map(\.label) == ["notes.txt"])
        #expect(conversation.composer.armedSkillName == "disk-triage")
    }

    @Test
    func manualCompactionIsRefusedWhileRunPreparationIsActive() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let controller = makeController(memory: memory)
        let conversation = ConversationModel()
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        await memoryStore.waitUntilPreparationEntered()
        #expect(conversation.isPreparingAgentRun)

        let didCompact = await controller.compact(conversation)
        #expect(!didCompact)
        #expect(conversation.compactionActivity == nil)
        #expect(conversation.isPreparingAgentRun)

        conversation.stop()
        await memoryStore.releasePreparation()
        try await waitUntil { !conversation.isPreparingAgentRun }
    }

    @Test
    func memoryDisabledDuringPreparationRevokesTheCapturedSession() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository, memory: memory)
        let conversation = ConversationModel()
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        await memoryStore.waitUntilPreparationEntered()
        await memory.setEnabled(false)
        await memoryStore.releasePreparation()

        try await waitUntil { !conversation.isPreparingAgentRun }
        #expect(!memory.isEnabled)
        #expect(conversation.runState == .failed)
        #expect(await memoryStore.preparationCallCount == 1)
    }

    @Test
    func memoryEnabledAfterCaptureIsNotAddedToTheTurn() async {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        let controller = makeController(memory: memory)
        let conversation = ConversationModel()
        conversation.composer.draft = "inspect"

        #expect(controller.sendAgentDraft(conversation))
        #expect(conversation.transcript.last?.contextSnapshot?.memorySessionID == nil)
        await memory.setEnabled(true)
        #expect(await memoryStore.preparationCallCount == 0)
    }

    @Test
    func legacyExplicitStartUsesANeutralUnknownSnapshot() async throws {
        let repository = RecordingAgentRunRepository()
        let (ai, _) = configuredAI(secret: "captured-secret")
        let controller = makeController(ai: ai, repository: repository)
        let legacy = AgentTranscriptMessage(role: .user, text: "legacy", authoredText: "legacy")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: legacy.id, role: .user, text: "legacy")], transcript: [legacy])
        conversation.isPlanning = true

        controller.startAgentRun(conversation)

        let snapshot = try #require(conversation.activeContextSnapshot)
        #expect(snapshot == AgentTurnContextSnapshot())
        conversation.stop()
        #expect(!conversation.isStreaming)
    }

    @Test
    func editFailurePreservesHistoryButUsesTheSynchronouslyCapturedReplacement() async throws {
        let repository = RecordingAgentRunRepository(failTruncation: true)
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])
        conversation.isPlanning = true
        let prepared = try #require(
            controller.prepareAgentEdit(
                conversation, messageID: message.id, text: "after",
                context: SessionContext(hostName: "captured-host")))
        conversation.isPlanning = false

        await #expect(throws: CocoaError.self) {
            try await controller.performAgentEdit(prepared, in: conversation, operations: operations)
        }
        #expect(conversation.transcript == [message])
        #expect(!conversation.isPreparingAgentRun)
        let replacement = try #require(await repository.truncationReplacement)
        #expect(replacement.authoredText == "after")
        #expect(replacement.contextSnapshot?.sessionContext?.contains("captured-host") == true)
        #expect(replacement.contextSnapshot?.planContract == TermindAgentPolicy.planContract)
    }

    @Test
    func successfulEditStartsFromTheCapturedReplacementSnapshot() async throws {
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])
        conversation.isPlanning = true
        let prepared = try #require(
            controller.prepareAgentEdit(
                conversation, messageID: message.id, text: "after",
                context: SessionContext(hostName: "captured-host")))
        conversation.isPlanning = false

        #expect(try await controller.performAgentEdit(prepared, in: conversation, operations: operations))
        let edited = try #require(conversation.transcript.first)
        #expect(edited.authoredText == "after")
        #expect(edited.contextSnapshot?.sessionContext?.contains("captured-host") == true)
        #expect(edited.contextSnapshot?.planContract == TermindAgentPolicy.planContract)
        await conversation.stopAndWait()
        #expect(conversation.runState == .failed)
        let failed = try #require(conversation.runSummaries.values.first)
        #expect(conversation.runSummaries.count == 1)
        #expect(failed.state == .failed)
        #expect(failed.id != edited.id)
        #expect(conversation.messageRunIDs[edited.id] == failed.id)
        #expect(conversation.runSummaries[edited.id] == nil)
    }

    @Test
    func failedReplacementSaveCannotBeSupersededOrMutatedBeforeItCompletes() async throws {
        let repository = RecordingAgentRunRepository(blocksFirstSave: true)
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let original = AgentTranscriptMessage(role: .user, text: "opening", authoredText: "opening")
        let answer = AgentTranscriptMessage(role: .assistant, text: "answer")
        let later = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [
                ChatMessage(id: original.id, role: .user, text: original.text),
                ChatMessage(id: answer.id, role: .assistant, text: answer.text),
                ChatMessage(id: later.id, role: .user, text: later.text),
            ], transcript: [original, answer, later])
        let prepared = try #require(
            controller.prepareAgentEdit(conversation, messageID: later.id, text: "after"))

        #expect(try await controller.performAgentEdit(prepared, in: conversation, operations: operations))
        await repository.waitUntilSaveEntered()
        let edited = try #require(conversation.transcript.last)

        #expect(conversation.messageRunIDs[edited.id] == edited.id)
        #expect(conversation.transcript.contains(where: { $0.id == answer.id }))
        #expect(controller.prepareAgentEdit(conversation, messageID: edited.id, text: "newer") == nil)
        #expect(
            try await operations.edit(conversation, messageID: edited.id, text: "bypass") == nil)
        #expect(try await operations.fork(conversation, at: answer.id, title: "Bypass") == nil)
        #expect(await repository.truncationCount == 1)

        await repository.releaseSave()
        await conversation.stopAndWait()

        #expect(conversation.runState == .failed)
        #expect(conversation.messageRunIDs[edited.id] != edited.id)
        #expect(conversation.runSummaries[edited.id] == nil)
    }

    @Test
    func failedSnapshotSaveRetiresPreparationWithoutAdoptingStaging() async throws {
        let repository = RecordingAgentRunRepository(blocksFirstSave: true, failsFirstSave: true)
        let controller = makeController(repository: repository)
        let operations = AssistantConversationOperations(repository: repository)
        let original = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: original.id, role: .user, text: original.text)],
            transcript: [original])
        let prepared = try #require(
            controller.prepareAgentEdit(conversation, messageID: original.id, text: "after"))

        #expect(try await controller.performAgentEdit(prepared, in: conversation, operations: operations))
        await repository.waitUntilSaveEntered()
        let edited = try #require(conversation.transcript.first)
        let staging = try #require(conversation.runSummaries[edited.id])
        #expect(conversation.messageRunIDs[edited.id] == edited.id)

        await repository.releaseSave()
        try await waitUntil { !conversation.isPreparingAgentRun }

        #expect(!conversation.isPersistingAgentPreparationFailure)
        #expect(conversation.messageRunIDs[edited.id] == edited.id)
        #expect(conversation.runSummaries[edited.id] == staging)
        #expect(conversation.runSummaries.values.allSatisfy { $0.state != .failed })
        #expect(conversation.messages.last?.role == .assistant)
        #expect(conversation.messages.last?.text == CocoaError(.fileWriteNoPermission).localizedDescription)
        #expect(await repository.completedSnapshots.isEmpty)
    }

    @Test
    func cancellationAfterSuccessfulEditAdoptsTheInterruptedRunProvenance() async throws {
        let memoryStore = PreparationBarrierMemoryStore()
        let memory = MemoryModel(storage: memoryStore)
        await memory.setEnabled(true)
        let repository = RecordingAgentRunRepository()
        let controller = makeController(repository: repository, memory: memory)
        let operations = AssistantConversationOperations(repository: repository)
        let message = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: "before")], transcript: [message])
        let prepared = try #require(
            controller.prepareAgentEdit(conversation, messageID: message.id, text: "after"))

        #expect(try await controller.performAgentEdit(prepared, in: conversation, operations: operations))
        let edited = try #require(conversation.transcript.first)
        #expect(conversation.messageRunIDs[edited.id] == edited.id)
        await memoryStore.waitUntilPreparationEntered()

        let cancellation = controller.cancelPendingRuns()
        await memoryStore.releasePreparation()
        await cancellation.value

        let interrupted = try #require(await repository.snapshots.last)
        #expect(interrupted.state == .interrupted)
        #expect(conversation.runState == .interrupted)
        #expect(conversation.messageRunIDs[edited.id] == interrupted.id)
        #expect(conversation.runSummaries[edited.id] == nil)
        #expect(conversation.runSummaries[interrupted.id]?.state == .interrupted)
    }

    private func makeController(
        ai: AIConfigurationModel = AIConfigurationModel(),
        skills: SkillLibraryModel = SkillLibraryModel(),
        repository: any AgentRunPersisting = RecordingAgentRunRepository(),
        memory: MemoryModel? = nil,
        authorize: @escaping @MainActor () -> Bool = { true },
        makeRegistry: @escaping AssistantExecutionController.RegistryFactory = { _, _, _, _, _, _, _ in
            AgentToolRegistry([])
        }
    ) -> AssistantExecutionController {
        AssistantExecutionController(
            ai: ai, skills: skills, repository: repository, memory: memory,
            authorize: authorize, makeRegistry: makeRegistry,
            title: { _ in "Title" })
    }

    private func configuredAI(secret: String?) -> (AIConfigurationModel, ModelProvider) {
        let model = AIModel(id: "captured-model", abilities: [.toolCall])
        let provider = ModelProvider(
            name: "Captured", inferenceURL: "https://example.invalid/v1/responses",
            credentialRef: "captured-key", models: [model])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        ai.setSecret(secret, for: provider.credentialRef)
        return (ai, provider)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2), _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TestTimeoutError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct TestTimeoutError: Error {}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

@MainActor
private final class JoinProbe {
    let expectedStarts: Int
    private(set) var startedCount = 0
    private(set) var completedCount = 0

    init(expectedStarts: Int) {
        self.expectedStarts = expectedStarts
    }

    func started() {
        startedCount += 1
    }

    func completed() {
        completedCount += 1
    }
}

@MainActor
private final class RegistryCapture {
    var modelID: String?
    var providerID: UUID?
    var catalog: AgentSkillCatalog?

    func record(model: AIModel, provider: ModelProvider, catalog: AgentSkillCatalog) {
        modelID = model.id
        providerID = provider.id
        self.catalog = catalog
    }
}

private actor PreparationBarrierMemoryStore: MemoryPersisting {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var preparationCallCount = 0

    func waitUntilPreparationEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releasePreparation() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func prepareSession(_ conversationID: UUID) async throws {
        preparationCallCount += 1
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }
    func learningProgress(_ conversationID: UUID) -> MemoryLearningProgress { .init() }
    func recordActivity(
        _ id: UUID, sourceMessageID: UUID, kind: MemoryActivityKind,
        conversationID: UUID
    ) -> MemoryLearningProgress { .init() }
    func correctionWasReviewed(_ messageID: UUID, conversationID: UUID) -> Bool { false }
    func applyCorrection(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState,
        messageID: UUID, conversationID: UUID
    ) -> AgentMemoryState? { expected }

    func memoryState() -> AgentMemoryState { AgentMemoryState() }
    func memoryReferenceDates() -> [UUID: Date] { [:] }
    func recordMemoryReferences(_ ids: [UUID], at date: Date) {}
    func applyMemory(_ operations: [AgentMemoryOperation]) -> AgentMemoryState { AgentMemoryState() }
    func replaceHistory(_ conversations: [StoredAgentConversation]) {}
    func rebuildHistoryIndex() {}
    func searchSessions(_ request: AgentSessionSearchRequest) -> AgentJSONValue { .array([]) }
    func lastReviewedMessage(_ conversationID: UUID) -> UUID? { nil }
    func markReviewed(_ messageID: UUID, conversationID: UUID) {}
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState,
        messageID: UUID, conversationID: UUID, reviewedActivityIDs: [UUID]
    ) -> AgentMemoryState? { expected }
    func replaceTarget(_ target: AgentMemoryTarget, text: String) -> AgentMemoryState { AgentMemoryState() }
    func close() {}
    func destroy() {}
}

private actor RecordingAgentRunRepository: AgentRunPersisting {
    private(set) var snapshots: [AgentRunSnapshot] = []
    private(set) var completedSnapshots: [AgentRunSnapshot] = []
    private(set) var events: [String] = []
    private(set) var truncationReplacement: AgentTranscriptMessage?
    private(set) var truncationCount = 0
    private(set) var metadataMutationCount = 0
    private(set) var deletionCount = 0
    private let failTruncation: Bool
    private let blocksFirstSave: Bool
    private let failsFirstSave: Bool
    private let blocksTruncation: Bool
    private var saveEntered = false
    private var saveReleased = false
    private var saveEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotWaiters: [(state: AgentRunState, continuation: CheckedContinuation<Void, Never>)] = []
    private var truncationEntered = false
    private var truncationReleased = false
    private var truncationEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var truncationReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        failTruncation: Bool = false, blocksFirstSave: Bool = false,
        blocksTruncation: Bool = false, failsFirstSave: Bool = false
    ) {
        self.failTruncation = failTruncation
        self.blocksFirstSave = blocksFirstSave
        self.blocksTruncation = blocksTruncation
        self.failsFirstSave = failsFirstSave
    }

    func save(_ snapshot: AgentRunSnapshot) async throws {
        snapshots.append(snapshot)
        events.append("save-attempt")
        var pendingSnapshotWaiters: [(state: AgentRunState, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in snapshotWaiters {
            if waiter.state == snapshot.state {
                waiter.continuation.resume()
            } else {
                pendingSnapshotWaiters.append(waiter)
            }
        }
        snapshotWaiters = pendingSnapshotWaiters
        if blocksFirstSave, snapshots.count == 1 {
            saveEntered = true
            let entryWaiters = saveEntryWaiters
            saveEntryWaiters.removeAll()
            for waiter in entryWaiters { waiter.resume() }
            if !saveReleased {
                await withCheckedContinuation { saveReleaseWaiters.append($0) }
            }
        }
        if failsFirstSave, snapshots.count == 1 {
            throw CocoaError(.fileWriteNoPermission)
        }
        completedSnapshots.append(snapshot)
        events.append("save-completed")
        let completionWaiters = saveCompletionWaiters
        saveCompletionWaiters.removeAll()
        for waiter in completionWaiters { waiter.resume() }
    }

    func waitUntilSaveEntered() async {
        if saveEntered { return }
        await withCheckedContinuation { saveEntryWaiters.append($0) }
    }

    func waitUntilSnapshot(state: AgentRunState) async {
        if snapshots.contains(where: { $0.state == state }) { return }
        await withCheckedContinuation { snapshotWaiters.append((state, $0)) }
    }

    func waitUntilSaveCompleted() async {
        if !completedSnapshots.isEmpty { return }
        await withCheckedContinuation { saveCompletionWaiters.append($0) }
    }

    func releaseSave() {
        saveReleased = true
        let waiters = saveReleaseWaiters
        saveReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilTruncationEntered() async {
        if truncationEntered { return }
        await withCheckedContinuation { truncationEntryWaiters.append($0) }
    }

    func releaseTruncation() {
        truncationReleased = true
        let waiters = truncationReleaseWaiters
        truncationReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func record(_ event: AgentEvent, runID: UUID) {}
    func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {
        deletionCount += 1
        events.append("delete")
    }
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) {
        metadataMutationCount += 1
        events.append("metadata")
    }
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) {}
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) async throws {
        truncationCount += 1
        if blocksTruncation {
            truncationEntered = true
            let waiters = truncationEntryWaiters
            truncationEntryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !truncationReleased {
                await withCheckedContinuation { truncationReleaseWaiters.append($0) }
            }
        }
        try Task.checkCancellation()
        truncationReplacement = message
        if failTruncation { throw CocoaError(.fileWriteNoPermission) }
    }
    func createConversation(_ conversation: StoredAgentConversation) {}
}
