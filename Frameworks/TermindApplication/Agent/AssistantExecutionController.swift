import AgentKit
import Foundation
import Logging
import TermindDomain

/// One runtime assembly and compaction policy for both app surfaces.
@MainActor
public final class AssistantExecutionController {
    public typealias RegistryFactory =
        @MainActor (
            ConversationModel, AIModel, ModelProvider, AgentSkillCatalog,
            AgentEventChannel, AgentPaneAccess?, AgentChatSourceContext
        )
        ->
        AgentToolRegistry
    private let ai: AIConfigurationModel
    private let skills: SkillLibraryModel
    private let memory: MemoryModel?
    private let agentRunRepository: any AgentRunPersisting
    private let modelSelections: AssistantModelSelectionController?
    public var observeNotifications: ((ConversationModel) -> Void)?
    public var reportModelSelectionError: (@MainActor (String) -> Void)?
    private let authorize: @MainActor () -> Bool
    private let makeRegistry: RegistryFactory
    private let title: @MainActor (ConversationTitleContext) async throws -> String
    private let logger: Logger
    private let agentCompaction = AgentCompactionService()
    private let guardianSessions = GuardianSessionStore()
    private var titledConversationIDs = Set<UUID>()
    private var preparations: [UUID: PreparationState] = [:]

    fileprivate struct GuardianCapture {
        var provider: ModelProvider
        var model: AIModel
        var secret: String
        var reasoning: ReasoningEffort
    }

    fileprivate struct RunCapture {
        var id: UUID
        var prompt: ConversationModel.ComposedUserTurn
        var contextSnapshot: AgentTurnContextSnapshot
        var permissionMode: AgentPermissionMode
        var reasoning: ReasoningEffort
        var chat: (provider: ModelProvider, model: AIModel)?
        var secret: String?
        var nativeSearch: Bool
        var skillCatalog: AgentSkillCatalog
        var skillInventory: [AgentSkill]
        var channel: AgentEventChannel?
        var baseRegistry: AgentToolRegistry?
        var guardian: GuardianCapture?
        var memorySessionID: UUID?
        var shouldCompact: Bool
        var compactionModel: (any AgentModelCompleting)?
        var memoryReviewModel: (any AgentModelCompleting)?
    }

    private struct PreparationState {
        enum Phase {
            case preparing
            case savingFailure
        }

        var id: UUID
        var conversation: ConversationModel
        var permissionMode: AgentPermissionMode
        var phase = Phase.preparing
        var task: Task<Void, Never>?
        var historyTask: Task<ConversationModel.ComposedUserTurn?, any Error>?
        var cancellationTask: Task<Void, Never>?
        var recordsInterruption = false
        var cancellationRequested = false
    }

    private enum StartResult {
        case runtimeStarted
        case failurePersistenceStarted
        case abandoned
    }

    public struct PreparedAgentEdit {
        fileprivate var capture: RunCapture
        fileprivate var replacement: AgentTranscriptMessage
        fileprivate var messageID: UUID
    }

    public struct PreparedAgentDelivery {
        fileprivate var capture: RunCapture
        public var message: AgentTranscriptMessage
    }

    @discardableResult
    public func cancelPendingRuns() -> Task<Void, Never> {
        var cancellationTasks: [Task<Void, Never>] = []
        for conversationID in Array(preparations.keys) {
            guard let state = preparations[conversationID] else { continue }
            cancellationTasks.append(
                requestCancellation(
                    for: state.conversation, expectedID: state.id,
                    recordsInterruption: true))
        }
        return Task { @MainActor in
            for task in cancellationTasks {
                await task.value
            }
        }
    }

    public init(
        ai: AIConfigurationModel, skills: SkillLibraryModel, repository: any AgentRunPersisting,
        memory: MemoryModel? = nil,
        modelSelections: AssistantModelSelectionController? = nil,
        reportModelSelectionError: (@MainActor (String) -> Void)? = nil,
        observeNotifications: ((ConversationModel) -> Void)? = nil,
        authorize: @escaping @MainActor () -> Bool, makeRegistry: @escaping RegistryFactory,
        title: @escaping @MainActor (ConversationTitleContext) async throws -> String,
        logger: Logger = ApplicationLogger.disabled("termind.agent")
    ) {
        self.ai = ai
        self.skills = skills
        self.memory = memory
        self.modelSelections = modelSelections
        self.reportModelSelectionError = reportModelSelectionError
        self.observeNotifications = observeNotifications
        agentRunRepository = repository
        self.authorize = authorize
        self.makeRegistry = makeRegistry
        self.title = title
        self.logger = logger
    }

    @discardableResult
    public func sendAgentDraft(
        _ conversation: ConversationModel,
        context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> Bool {
        guard
            let capture = captureDraft(
                conversation, context: context,
                terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: panes)
        else { return false }
        startPreparation(capture, for: conversation, compactBeforeRun: true)
        return true
    }

    @discardableResult
    public func sendNewConversation(
        _ conversation: ConversationModel, in library: AssistantLibraryModel,
        context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> ConversationModel? {
        guard library.canPromote(conversation),
            let capture = captureDraft(
                conversation, context: context,
                terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: panes)
        else { return nil }
        guard library.promoteCapturedConversation(conversation) else {
            cancelCapturedTurn(capture, in: conversation)
            return nil
        }
        startPreparation(capture, for: conversation, compactBeforeRun: true)
        return conversation
    }

    @discardableResult
    public func sendDraftConversation(
        in library: AssistantLibraryModel,
        context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> ConversationModel? {
        let conversation = library.draftConversation
        guard library.canPromote(conversation),
            let capture = captureDraft(
                conversation, context: context,
                terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: panes)
        else { return nil }
        guard library.promoteCapturedDraftConversation(conversation) else {
            cancelCapturedTurn(capture, in: conversation)
            return nil
        }
        startPreparation(capture, for: conversation, compactBeforeRun: true)
        return conversation
    }

    @discardableResult
    public func sendAgentText(
        _ text: String, in conversation: ConversationModel,
        context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> Bool {
        guard authorize(), canSubmit(to: conversation),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            conversation.composer.pendingAttachments.isEmpty
        else { return false }
        let prompt = conversation.composeUserTurn(text)
        let snapshot = contextSnapshot(
            for: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
        guard
            let capture = captureRun(
                conversation, prompt: prompt, contextSnapshot: snapshot,
                beginPreparation: true, panes: panes)
        else { return false }
        let submittedPrompt = conversation.appendUserTurnContent(
            capture.prompt, contextSnapshot: capture.contextSnapshot)
        var submitted = capture
        submitted.prompt = submittedPrompt
        startPreparation(submitted, for: conversation, compactBeforeRun: true)
        return true
    }

    @discardableResult
    public func sendPlanImplementation(
        _ card: AgentPlanCard, in conversation: ConversationModel,
        context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> Bool {
        guard authorize(), canSubmit(to: conversation),
            conversation.composer.pendingAttachments.isEmpty,
            let pending = conversation.plans.first(where: {
                $0.id == card.id && $0.outcome == .pending
            })
        else { return false }
        let prompt = conversation.composeUserTurn(
            ConversationModel.implementationPrompt(for: pending.plan))
        var snapshot = contextSnapshot(
            for: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
        snapshot.planContract = nil
        guard
            let capture = captureRun(
                conversation, prompt: prompt, contextSnapshot: snapshot,
                beginPreparation: true, panes: panes)
        else { return false }
        let submittedPrompt = conversation.appendUserTurnContent(
            capture.prompt, contextSnapshot: capture.contextSnapshot)
        conversation.resolvePlan(card.id, as: .implemented)
        var submitted = capture
        submitted.prompt = submittedPrompt
        startPreparation(submitted, for: conversation, compactBeforeRun: true)
        return true
    }

    public func prepareAgentEdit(
        _ conversation: ConversationModel, messageID: UUID, text: String,
        context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> PreparedAgentEdit? {
        guard authorize(), !conversation.isStreaming, !conversation.isArchived,
            !conversation.isCompacting, !conversation.isHistoryChanging,
            var replacement = conversation.editedUserMessage(messageID, authoredText: text)
        else { return nil }
        let snapshot = contextSnapshot(
            for: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
        replacement.contextSnapshot = snapshot
        let prompt = ConversationModel.ComposedUserTurn(
            id: replacement.id, text: replacement.text,
            authoredText: replacement.authoredText ?? text, images: replacement.images,
            contextAttachments: replacement.contextAttachments)
        guard
            let capture = captureRun(
                conversation, prompt: prompt, contextSnapshot: snapshot,
                beginPreparation: true, supersedePreparation: true, panes: panes)
        else { return nil }
        return PreparedAgentEdit(capture: capture, replacement: replacement, messageID: messageID)
    }

    public func performAgentEdit(
        _ prepared: PreparedAgentEdit, in conversation: ConversationModel,
        operations: AssistantConversationOperations
    ) async throws -> Bool {
        let capture = prepared.capture
        guard isCurrent(capture, for: conversation) else { return false }
        let historyTask = Task { @MainActor in
            try Task.checkCancellation()
            return try await operations.edit(
                conversation, messageID: prepared.messageID, replacement: prepared.replacement)
        }
        guard var state = preparations[conversation.id], state.id == capture.id,
            !state.cancellationRequested
        else {
            historyTask.cancel()
            return false
        }
        state.historyTask = historyTask
        preparations[conversation.id] = state
        do {
            guard let edited = try await historyTask.value else {
                guard isCurrent(capture, for: conversation) else { return false }
                retirePreparation(capture.id, for: conversation)
                return false
            }
            guard isCurrent(capture, for: conversation) else { return false }
            if var state = preparations[conversation.id], state.id == capture.id {
                state.historyTask = nil
                preparations[conversation.id] = state
            }
            var submitted = capture
            submitted.prompt = edited
            startPreparation(submitted, for: conversation, compactBeforeRun: false)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(capture, for: conversation) else { return false }
            retirePreparation(capture.id, for: conversation)
            throw error
        }
    }

    /// Captures the target's own run settings while keeping the incoming agent text
    /// outside its composer, attachments, armed skill, and model picker state.
    public func prepareIncomingAgentMessage(
        _ text: String, origin: AgentMessageOrigin, in conversation: ConversationModel
    ) -> PreparedAgentDelivery? {
        guard authorize(), canSubmit(to: conversation), !text.isEmpty else { return nil }
        let snapshot = contextSnapshot(
            for: conversation, context: .none,
            terminalSuggestionsAvailable: false)
        let prompt = conversation.composeIncomingAgentTurn(text, origin: origin)
        guard
            let capture = captureRun(
                conversation, prompt: prompt, contextSnapshot: snapshot,
                beginPreparation: true, panes: nil)
        else { return nil }
        let message = AgentTranscriptMessage(
            id: prompt.id, role: .user, text: prompt.text,
            authoredText: nil, contextSnapshot: snapshot, origin: origin)
        return PreparedAgentDelivery(capture: capture, message: message)
    }

    /// Persists the incoming prompt as a staging run before the coordinator accepts
    /// delivery. The real run adopts this row when it starts.
    public func persistPreparedAgentDelivery(
        _ prepared: PreparedAgentDelivery, in conversation: ConversationModel
    ) async throws {
        let capture = prepared.capture
        guard isCurrent(capture, for: conversation) else { throw CancellationError() }
        try await agentRunRepository.save(
            AgentRunSnapshot(
                id: prepared.message.id, conversationID: conversation.id,
                state: .completed, permissionMode: capture.permissionMode,
                messages: [prepared.message], startedAt: prepared.message.createdAt,
                finishedAt: prepared.message.createdAt))
        // The prompt save is the acceptance boundary and, for durable stores,
        // atomically confirms its delivery receipt. Metadata is useful but not
        // allowed to turn that accepted message into an orphan outside the live
        // library when a later write fails.
        try? await agentRunRepository.setConversationMetadata(
            conversation.metadata, conversationID: conversation.id)
    }

    public func startPreparedAgentDelivery(
        _ prepared: PreparedAgentDelivery, in conversation: ConversationModel
    ) {
        let capture = prepared.capture
        guard isCurrent(capture, for: conversation) else { return }
        guard
            let prompt = conversation.appendIncomingAgentTurnContent(
                capture.prompt, contextSnapshot: capture.contextSnapshot)
        else {
            Task { await cancelPreparedAgentDelivery(prepared, in: conversation) }
            return
        }
        var submitted = capture
        submitted.prompt = prompt
        startPreparation(submitted, for: conversation, compactBeforeRun: true)
    }

    public func cancelPreparedAgentDelivery(
        _ prepared: PreparedAgentDelivery, in conversation: ConversationModel
    ) async {
        guard isCurrent(prepared.capture, for: conversation) else { return }
        await requestCancellation(
            for: conversation, expectedID: prepared.capture.id,
            recordsInterruption: false
        ).value
    }

    private func captureDraft(
        _ conversation: ConversationModel, context: SessionContext,
        terminalSuggestionsAvailable: Bool, panes: AgentPaneAccess?
    ) -> RunCapture? {
        guard authorize(), canSubmit(to: conversation), conversation.canSendDraft,
            conversation.composer.pendingAttachments.isEmpty
        else { return nil }
        let draft = conversation.composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = contextSnapshot(
            for: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
        let preview = conversation.composeUserTurn(draft)
        guard
            var capture = captureRun(
                conversation, prompt: preview, contextSnapshot: snapshot,
                beginPreparation: true, panes: panes)
        else { return nil }
        capture.prompt = conversation.appendUserTurnContent(preview, contextSnapshot: snapshot)
        conversation.composer.draft = ""
        return capture
    }

    public func startAgentRun(
        _ conversation: ConversationModel,
        promptID: UUID? = nil,
        prompt: String? = nil,
        authoredPrompt: String? = nil,
        promptImages: [AgentImageAttachment]? = nil,
        promptContextAttachments: [AgentContextAttachment]? = nil,
        context: SessionContext? = nil,
        terminalSuggestionsAvailable: Bool = false,
        panes: AgentPaneAccess? = nil
    ) {
        guard authorize(), canSubmit(to: conversation) else { return }
        let lastUserTurn = conversation.transcript.last(where: { $0.role == .user })
        let resolvedPrompt = ConversationModel.ComposedUserTurn(
            id: promptID ?? lastUserTurn?.id ?? UUID(),
            text: prompt ?? lastUserTurn?.text ?? "",
            authoredText: authoredPrompt ?? lastUserTurn?.authoredText ?? "",
            images: promptImages ?? lastUserTurn?.images ?? [],
            contextAttachments: promptContextAttachments ?? lastUserTurn?.contextAttachments ?? [],
            origin: lastUserTurn?.origin)
        guard
            !resolvedPrompt.text.isEmpty || !resolvedPrompt.images.isEmpty
                || !resolvedPrompt.contextAttachments.isEmpty
        else { return }
        // A legacy absent snapshot is unknown. Do not manufacture historical
        // session, skill, plan, memory, or surface facts from today's UI.
        let snapshot = lastUserTurn?.contextSnapshot ?? AgentTurnContextSnapshot()
        guard
            let capture = captureRun(
                conversation, prompt: resolvedPrompt, contextSnapshot: snapshot,
                beginPreparation: true, panes: panes)
        else { return }
        startPreparation(capture, for: conversation, compactBeforeRun: false)
    }

    private func performStartAgentRun(
        _ conversation: ConversationModel, capture: RunCapture,
        memorySession: (context: AgentMemoryContext, access: any AgentMemoryAccessing)? = nil
    ) -> StartResult {
        guard isCurrent(capture, for: conversation), !conversation.isStreaming,
            !conversation.isArchived, !conversation.isHistoryChanging
        else { return .abandoned }
        let operationID = UUID().uuidString.lowercased()
        let conversationID = conversation.id.uuidString.lowercased()
        guard let chat = capture.chat else {
            logger.error(
                "agent.run.failed",
                metadata: [
                    "conversation_id": "\(conversationID)", "error_code": "missing_model",
                    "operation_id": "\(operationID)", "outcome": "failure", "stage": "preparing",
                ])
            beginFailedRunPersistence(
                conversation, capture: capture,
                reason: String(localized: "No Chat model is configured.")
            )
            return .failurePersistenceStarted
        }
        guard let secret = capture.secret else {
            logger.error(
                "agent.run.failed",
                metadata: [
                    "conversation_id": "\(conversationID)", "error_code": "missing_credential",
                    "operation_id": "\(operationID)", "outcome": "failure", "stage": "preparing",
                ])
            beginFailedRunPersistence(
                conversation, capture: capture,
                reason: String(localized: "The Chat model has no available credential.")
            )
            return .failurePersistenceStarted
        }

        let model = AgentProviderClient(
            provider: chat.provider, model: chat.model, secret: secret,
            reasoning: capture.reasoning,
            webSearch: capture.nativeSearch, promptCacheKey: conversation.id.uuidString
        )
        // One channel for the whole run, shared by everything that publishes
        // into it. The broker used to raise its review events through a closure
        // of its own, each wrapped in an unstructured `Task` — so a review's
        // events had no defined order against the tool events they belong
        // between, and its durable writes had no defined order against
        // anything. See `AgentEventChannel`.
        guard let channel = capture.channel, let baseRegistry = capture.baseRegistry else { return .abandoned }
        let skillCatalog = capture.skillCatalog
        let skillRegistry = AgentToolCatalog.registry(
            builtIn: .init(
                groups: [.skills, .memory], skills: skillCatalog, skillInventory: capture.skillInventory,
                readOnlySkillNames: AgentSkillLibrary.reservedNames,
                skillPackageResolver: GitHubSkillPackageResolver(), skillLibrary: skills,
                memory: memorySession?.access))
        let registry =
            chat.model.abilities.contains(.toolCall)
            ? AgentToolRegistry(skillRegistry.registeredTools + baseRegistry.registeredTools) : baseRegistry
        let interaction = WeakAgentUserInteraction(conversation)
        let services = AgentToolServices()
            .setting(interaction.sshInteraction, for: .sshInteraction)
        let guardianServices = AgentToolServices()
            .setting(AgentSSHInteraction.unavailable, for: .sshInteraction)
        let reviewer: (any GuardianReviewing)? = {
            guard capture.permissionMode == .approveForMe, let review = capture.guardian else { return nil }
            let reviewTools =
                review.model.abilities.contains(.toolCall)
                ? registry : AgentToolRegistry([])
            return GuardianClient(
                model: AgentProviderClient(
                    provider: review.provider, model: review.model, secret: review.secret,
                    reasoning: review.reasoning,
                    promptCacheKey: TermindAgentPolicy.guardianCacheKey(conversationID: conversation.id)
                ),
                sessions: guardianSessions,
                sessionID: "\(conversation.id.uuidString):\(review.provider.id):\(review.model.id)",
                tools: reviewTools,
                services: guardianServices,
                additionalPolicy: TermindAgentPolicy.guardianPolicy
            )
        }()
        // Weakly. The conversation owns the runtime, the runtime owns the broker
        // and the interaction handler, and both of those used to own the
        // conversation back — so every chat that had ever run an agent stayed
        // alive, with its runtime, for the life of the process. A conversation
        // that is gone denies and cancels: fail closed.
        let approval = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { [weak conversation] request in
                guard let conversation else {
                    return .deny(String(localized: "The conversation was closed before this action was approved."))
                }
                return await conversation.requestApproval(request)
            },
            reviewTimeout: .seconds(90),
            event: channel.emit
        )
        // The one place the resolved tool set exists. Recorded on the
        // conversation so the context gauge can account for the schemas without
        // rebuilding a registry on every keystroke.
        conversation.noteToolSchemas(registry.descriptors)
        // Read once, here: the posture a run enforces is the one it started
        // under, and the user is free to leave plan mode while it is thinking.
        let frozenContext = capture.contextSnapshot
        let isPlanning = frozenContext.planContract != nil
        // The catalog reaches the model boundary through the pipeline rather
        // than through the system prompt, so the prompt stays byte-identical for
        // every run and the provider's prefix cache survives a skill being
        // enabled. See `AgentSkillCatalogInjection`.
        var configuration = AgentLoopConfiguration()
        // Termind draws the reply as it streams, so the bursts a provider
        // delivers in need smoothing before they reach a view. A surface that
        // only records events would leave this off — see `AgentStreamPacing`.
        configuration.streamPacing = .animated
        configuration.outputProjection = AgentToolOutputProjection(
            workspace: AgentScratchWorkspace(
                conversationID: conversation.id, applicationName: TermindAgentPolicy.scratchDirectoryName))
        configuration.contextSnapshot = { _, _ in frozenContext }
        configuration.contextPipeline = { sessionContext, promptID, planning in
            var pipeline = AgentContextPipeline.chat(
                sessionContext: sessionContext, before: promptID,
                isPlanning: planning, skills: skillCatalog,
                planContract: TermindAgentPolicy.planContract
            )
            if let memorySession { pipeline.transforms.append(memorySession.context) }
            return pipeline
        }
        let runtime = AgentRuntime(
            model: model, registry: registry,
            approval: approval,
            repository: agentRunRepository,
            userInteraction: interaction,
            services: services,
            hooks: [TermindAgentPolicy.planModeHook(isPlanning: isPlanning)],
            configuration: configuration,
            channel: channel
        )
        // No second Shell Integration gate here. `Pane.remoteSystemInfo` already
        // withholds the probe when integration was disabled at connection start, and `context` is the same
        // value the chips were drawn from — so what is shown and what is sent
        // cannot disagree.
        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id,
                promptID: capture.prompt.id, prompt: capture.prompt.text,
                authoredPrompt: capture.prompt.origin == nil ? capture.prompt.authoredText : nil,
                promptOrigin: capture.prompt.origin,
                promptImages: capture.prompt.images,
                promptContextAttachments: capture.prompt.contextAttachments,
                permissionMode: capture.permissionMode, isPlanning: isPlanning,
                systemPrompt: TermindAgentPolicy.systemPrompt,
                priorMessages: conversation.pendingPriorMessages,
                authorizationEvidence: GuardianEvidence.collect(from: conversation.transcript),
                sessionContext: frozenContext.sessionContext, contextSnapshot: frozenContext
            ),
            repository: agentRunRepository
        )
        logger.info(
            "agent.run.started",
            metadata: [
                "conversation_id": "\(conversationID)", "operation_id": "\(operationID)",
                "planning": "\(isPlanning)", "stage": "running", "tool_count": "\(registry.registeredTools.count)",
            ])
        scheduleTitle(
            for: conversation, isPlanning: isPlanning, operationID: operationID,
            memoryToken: memorySession.flatMap { memory?.learningToken(for: $0.context) },
            reviewModel: capture.memoryReviewModel)
        return .runtimeStarted
    }

    private func canSubmit(to conversation: ConversationModel) -> Bool {
        !conversation.isArchived && !conversation.isStreaming && !conversation.isCompacting
            && !conversation.isHistoryChanging && !conversation.isPreparingAgentRun
    }

    private func captureRun(
        _ conversation: ConversationModel,
        prompt: ConversationModel.ComposedUserTurn,
        contextSnapshot: AgentTurnContextSnapshot,
        beginPreparation: Bool,
        supersedePreparation: Bool = false,
        panes: AgentPaneAccess? = nil
    ) -> RunCapture? {
        do {
            try modelSelections?.prepareForSend(conversation)
        } catch {
            reportModelSelectionError?(error.localizedDescription)
            return nil
        }
        let id = UUID()
        let chat = ai.resolve(conversation: conversation.model)
        let secret = chat.flatMap { ai.modelSecret(for: $0.provider) }
        let permissionMode = ai.resolve(conversation: conversation.permissionMode)
        let nativeSearch =
            chat.map {
                ai.webSearch.isEnabled && ai.webSearch.prefersBuiltIn
                    && $0.provider.supportsNativeWebSearch(model: $0.model)
            } ?? false
        let skillCatalog =
            chat?.model.abilities.contains(.toolCall) == true
            ? skills.catalog : AgentSkillCatalog()
        let skillInventory = skills.inventory
        let channel = chat != nil && secret != nil ? AgentEventChannel(repository: agentRunRepository) : nil
        let baseRegistry = channel.flatMap { channel in
            chat.map {
                let modelReference = AIModelRef(
                    modelProviderID: $0.provider.id, modelID: $0.model.id)
                return makeRegistry(
                    conversation, $0.model, $0.provider, skillCatalog, channel, panes,
                    AgentChatSourceContext(
                        conversationID: conversation.id, title: conversation.derivedTitle,
                        modelReference: AssistantChatCoordinator.reference(modelReference),
                        permissionMode: permissionMode,
                        mode: conversation.isPlanning ? .planning : .acting))
            }
        }
        let guardian: GuardianCapture? = {
            guard permissionMode == .approveForMe, let review = ai.resolve(.guardian),
                let secret = ai.modelSecret(for: review.provider)
            else { return nil }
            return GuardianCapture(
                provider: review.provider, model: review.model, secret: secret,
                reasoning: GuardianClient.preferredReasoning(
                    model: review.model, provider: review.provider))
        }()
        let contextWindow = chat?.model.contextLength
        let shouldCompact =
            conversation.usage.map {
                AgentCompaction.shouldCompact(
                    contextTokens: $0.contextTokens, contextWindow: contextWindow,
                    reserveTokens: compactionBudget.reserveTokens)
            } ?? false
        let capture = RunCapture(
            id: id, prompt: prompt, contextSnapshot: contextSnapshot,
            permissionMode: permissionMode, reasoning: conversation.reasoningEffort,
            chat: chat, secret: secret, nativeSearch: nativeSearch,
            skillCatalog: skillCatalog, skillInventory: skillInventory,
            channel: channel, baseRegistry: baseRegistry, guardian: guardian,
            memorySessionID: contextSnapshot.memorySessionID,
            shouldCompact: shouldCompact, compactionModel: compactionModel(),
            memoryReviewModel: memoryReviewModel(conversation))
        guard beginPreparation else { return capture }
        let cancellation: @MainActor () -> Task<Void, Never> = { [weak self, weak conversation] in
            guard let self, let conversation else { return Task {} }
            return self.requestCancellation(
                for: conversation, expectedID: id, recordsInterruption: true)
        }
        if supersedePreparation {
            if let current = preparations[conversation.id] {
                guard current.phase != .savingFailure else { return nil }
                _ = requestCancellation(
                    for: conversation, expectedID: current.id,
                    recordsInterruption: false)
            }
            preparations[conversation.id] = PreparationState(
                id: id, conversation: conversation, permissionMode: permissionMode)
            conversation.supersedeAgentPreparation(id: id, cancellation: cancellation)
            return capture
        }
        let installed = conversation.beginAgentPreparation(id: id, cancellation: cancellation)
        guard installed else { return nil }
        preparations[conversation.id] = PreparationState(
            id: id, conversation: conversation, permissionMode: permissionMode)
        return capture
    }

    private func startPreparation(
        _ capture: RunCapture, for conversation: ConversationModel,
        compactBeforeRun: Bool
    ) {
        guard isCurrent(capture, for: conversation) else { return }
        observeNotifications?(conversation)
        let needsAsync = (compactBeforeRun && capture.shouldCompact) || capture.memorySessionID != nil
        guard needsAsync else {
            switch performStartAgentRun(conversation, capture: capture) {
            case .runtimeStarted, .abandoned:
                retirePreparation(capture.id, for: conversation)
            case .failurePersistenceStarted:
                break
            }
            return
        }
        let task = Task { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            if compactBeforeRun, capture.shouldCompact {
                await compactCaptured(conversation, capture: capture)
            }
            guard !Task.isCancelled, isCurrent(capture, for: conversation) else {
                await finishCancelledPreparation(capture, for: conversation)
                return
            }
            let memorySession: (context: AgentMemoryContext, access: any AgentMemoryAccessing)?
            if let memorySessionID = capture.memorySessionID, let memory {
                memorySession = await memory.session(memorySessionID)
            } else {
                memorySession = nil
            }
            guard !Task.isCancelled, isCurrent(capture, for: conversation) else {
                await finishCancelledPreparation(capture, for: conversation)
                return
            }
            switch performStartAgentRun(conversation, capture: capture, memorySession: memorySession) {
            case .runtimeStarted, .abandoned:
                retirePreparation(capture.id, for: conversation)
            case .failurePersistenceStarted:
                break
            }
        }
        guard var state = preparations[conversation.id], state.id == capture.id else {
            task.cancel()
            return
        }
        state.task = task
        preparations[conversation.id] = state
    }

    private func compactCaptured(_ conversation: ConversationModel, capture: RunCapture) async {
        guard let model = capture.compactionModel, !conversation.isStreaming, !conversation.isCompacting else { return }
        conversation.beginCompaction()
        guard let span = conversation.compactionSpan(keepRecentTokens: compactionBudget.keepRecentTokens) else {
            conversation.endCompaction()
            return
        }
        do {
            if capture.contextSnapshot.planContract == nil, let memory,
                let review = capture.memoryReviewModel
            {
                await memory.review(
                    conversationID: conversation.id, messages: conversation.transcript,
                    model: review, wait: true)
            }
            try Task.checkCancellation()
            let summary = try await agentCompaction.summarize(
                span.summarize, instructions: "",
                toolResultLimit: compactionBudget.toolResultLimit, model: model)
            try Task.checkCancellation()
            guard isCurrent(capture, for: conversation),
                let record = conversation.prepareCompaction(summary: summary, cut: span.cut)
            else { throw CancellationError() }
            try await persistAndApplyCompaction(record, to: conversation, cut: span.cut)
            conversation.endCompaction()
        } catch is CancellationError {
            conversation.endCompaction()
        } catch {
            conversation.failCompaction(error.localizedDescription)
        }
    }

    private func isCurrent(_ capture: RunCapture, for conversation: ConversationModel) -> Bool {
        guard let state = preparations[conversation.id] else { return false }
        return state.id == capture.id && !state.cancellationRequested
    }

    private func retirePreparation(_ id: UUID, for conversation: ConversationModel) {
        guard preparations[conversation.id]?.id == id else { return }
        preparations[conversation.id] = nil
        conversation.finishAgentPreparation(id: id)
    }

    private func cancelCapturedTurn(_ capture: RunCapture, in conversation: ConversationModel) {
        guard isCurrent(capture, for: conversation) else { return }
        preparations[conversation.id]?.task?.cancel()
        retirePreparation(capture.id, for: conversation)
    }

    /// Invalidates a captured run before returning to the caller. The task only
    /// joins asynchronous work and persists the terminal snapshot; it never
    /// decides whether the runtime may still start.
    private func requestCancellation(
        for conversation: ConversationModel, expectedID: UUID? = nil,
        recordsInterruption: Bool
    ) -> Task<Void, Never> {
        guard var state = preparations[conversation.id],
            expectedID == nil || state.id == expectedID
        else { return Task {} }
        if state.phase == .savingFailure {
            return state.task ?? Task {}
        }
        state.recordsInterruption = state.recordsInterruption || recordsInterruption
        state.cancellationRequested = true
        state.task?.cancel()
        state.historyTask?.cancel()
        if let cancellationTask = state.cancellationTask {
            preparations[conversation.id] = state
            return cancellationTask
        }
        preparations[conversation.id] = state
        let preparationTask = state.task
        let historyTask = state.historyTask
        let preparationID = state.id
        let cancellationTask = Task { @MainActor [weak self, weak conversation] in
            guard let self, let conversation else { return }
            if let historyTask {
                _ = try? await historyTask.value
            }
            if let preparationTask {
                await preparationTask.value
            }
            await finishCancelledPreparation(
                preparationID, for: conversation)
        }
        state.cancellationTask = cancellationTask
        preparations[conversation.id] = state
        return cancellationTask
    }

    private func finishCancelledPreparation(
        _ capture: RunCapture, for conversation: ConversationModel
    ) async {
        guard let state = preparations[conversation.id], state.id == capture.id else { return }
        if state.recordsInterruption {
            let now = Date.now
            do {
                let snapshot = AgentRunSnapshot(
                    conversationID: conversation.id, state: .interrupted,
                    permissionMode: capture.permissionMode,
                    messages: conversation.transcript, startedAt: now, finishedAt: now)
                try await agentRunRepository.save(snapshot)
                guard preparations[conversation.id]?.id == capture.id else { return }
                conversation.adoptStagedReplacementRun(snapshot)
                conversation.handle(.runState(.interrupted))
            } catch {
                guard preparations[conversation.id]?.id == capture.id else { return }
                conversation.messages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            }
        }
        retirePreparation(capture.id, for: conversation)
    }

    private func finishCancelledPreparation(
        _ preparationID: UUID, for conversation: ConversationModel
    ) async {
        guard let state = preparations[conversation.id], state.id == preparationID else { return }
        if state.recordsInterruption {
            let now = Date.now
            do {
                let snapshot = AgentRunSnapshot(
                    conversationID: conversation.id, state: .interrupted,
                    permissionMode: state.permissionMode,
                    messages: conversation.transcript, startedAt: now, finishedAt: now)
                try await agentRunRepository.save(snapshot)
                guard preparations[conversation.id]?.id == preparationID else { return }
                conversation.adoptStagedReplacementRun(snapshot)
                conversation.handle(.runState(.interrupted))
            } catch {
                guard preparations[conversation.id]?.id == preparationID else { return }
                conversation.messages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            }
        }
        retirePreparation(preparationID, for: conversation)
    }

    private func beginFailedRunPersistence(
        _ conversation: ConversationModel, capture: RunCapture, reason: String
    ) {
        guard var state = preparations[conversation.id], state.id == capture.id else { return }
        var messages = conversation.pendingPriorMessages
        if !messages.contains(where: { $0.id == capture.prompt.id }) {
            messages.append(
                AgentTranscriptMessage(
                    id: capture.prompt.id, role: .user, text: capture.prompt.text,
                    authoredText: capture.prompt.authoredText, images: capture.prompt.images,
                    contextAttachments: capture.prompt.contextAttachments,
                    contextSnapshot: capture.contextSnapshot
                ))
        }
        let now = Date.now
        let snapshot = AgentRunSnapshot(
            conversationID: conversation.id, state: .failed,
            permissionMode: capture.permissionMode,
            messages: messages, startedAt: now, finishedAt: now,
            failure: reason
        )
        conversation.beginAgentPreparationFailurePersistence(id: capture.id)
        state.phase = .savingFailure
        let preparationID = capture.id
        let task = Task { @MainActor [self, conversation, agentRunRepository] in
            do {
                try await agentRunRepository.save(snapshot)
                guard preparations[conversation.id]?.id == preparationID else { return }
                conversation.recordFailedRun(snapshot)
            } catch {
                guard preparations[conversation.id]?.id == preparationID else { return }
                conversation.messages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            }
            retirePreparation(preparationID, for: conversation)
        }
        state.task = task
        preparations[conversation.id] = state
    }

    public func contextSnapshot(
        for conversation: ConversationModel, context: SessionContext, terminalSuggestionsAvailable: Bool
    ) -> AgentTurnContextSnapshot {
        let catalog =
            ai.resolve(conversation: conversation.model)?.model.abilities.contains(.toolCall) == true
            ? skills.catalog : AgentSkillCatalog()
        return AgentTurnContextSnapshot(
            sessionContext: context.modelContext,
            skillCatalog: catalog.isEmpty ? nil : catalog.catalogBlock,
            planContract: conversation.isPlanning ? TermindAgentPolicy.planContract : nil,
            toolAvailability: ["terminal_suggest": terminalSuggestionsAvailable],
            memorySessionID: memory?.isEnabled == true
                ? (conversation.transcript.first(where: { $0.contextSnapshot?.memorySessionID != nil })?
                    .contextSnapshot?.memorySessionID ?? conversation.id) : nil
        )
    }

    /// Which of the two web-search paths this turn gets, resolved once so the
    /// request body and the tool list cannot disagree.
    ///
    /// Native wins where it exists. It searches better than a snippet API can,
    /// costs no second key, and needs no round trip through Termind — the model
    /// simply knows things. What it gives up is visibility, which
    /// `AgentRuntime.recordNativeWebSearch` buys back after the fact.
    ///
    // MARK: - Compaction

    /// Summarizes the older part of a conversation so it can keep going.
    ///
    /// Never while a run is in flight: the transcript it would rewrite is the
    /// one the runtime is appending to, and the two would disagree about what
    /// the conversation is. `/compact` during a run is refused rather than
    /// queued, because by the time the run ends the thing the user wanted
    /// compacted has changed.
    @discardableResult
    public func compact(
        _ conversation: ConversationModel,
        instructions: String = "",
        isManual: Bool = true
    ) async -> Bool {
        guard authorize() else { return false }
        guard !conversation.isAgentRunActive, !conversation.isCompacting else { return false }
        conversation.beginCompaction()
        guard
            let span = conversation.compactionSpan(
                keepRecentTokens: compactionBudget.keepRecentTokens
            )
        else {
            if isManual {
                conversation.failCompaction(
                    AgentCompactionError.nothingToCompact.localizedDescription
                )
            } else {
                conversation.endCompaction()
            }
            return false
        }
        guard let model = compactionModel() else {
            conversation.failCompaction(AgentCompactionError.missingModel.localizedDescription)
            return false
        }

        do {
            if !conversation.isPlanning, let memory, let review = memoryReviewModel(conversation) {
                await memory.review(
                    conversationID: conversation.id, messages: conversation.transcript, model: review, wait: true)
            }
            let summary = try await agentCompaction.summarize(
                span.summarize, instructions: instructions,
                toolResultLimit: compactionBudget.toolResultLimit, model: model
            )
            guard
                let record = conversation.prepareCompaction(
                    summary: summary, cut: span.cut
                )
            else {
                throw AgentCompactionError.nothingToCompact
            }
            try await persistAndApplyCompaction(record, to: conversation, cut: span.cut)
            conversation.endCompaction()
            return true
        } catch {
            conversation.failCompaction(error.localizedDescription)
            return false
        }
    }

    /// The atomicity boundary for compaction: persistence happens first, and
    /// the observable model changes only after that succeeds.
    public func persistAndApplyCompaction(
        _ record: AgentCompactionRecord, to conversation: ConversationModel, cut: Int
    ) async throws {
        try await agentRunRepository.persistCompaction(
            record, conversationID: conversation.id
        )
        conversation.applyCompaction(record, cut: cut)
    }

    /// Resolves the Chat model with reasoning clamped off, like titling does.
    ///
    /// Summarizing is not a task that improves with a thinking budget, and this
    /// runs on the user's own key at the moment their conversation is already
    /// expensive.
    private func compactionModel() -> (any AgentModelCompleting)? {
        guard let resolved = ai.resolve(.chat) else { return nil }
        guard let secret = ai.modelSecret(for: resolved.provider)
        else { return nil }
        let reasoning = ModelCapabilityResolver.reasoning(
            model: resolved.model, provider: resolved.provider
        ).clamp(.off)
        return AgentProviderClient(
            provider: resolved.provider, model: resolved.model, secret: secret,
            reasoning: reasoning
        )
    }

    /// What a compaction is allowed to keep, reserve, and show the summarizer.
    ///
    /// One value rather than three, so a future Settings control changes them
    /// together — see `AgentCompaction.Budget`. Termind ships the defaults.
    private var compactionBudget: AgentCompaction.Budget { .default }

    /// Exactly one path is ever live. Offering both would put two tools in
    /// front of the model for one job and leave it to guess which, and the
    /// guess would decide whether the search shows up as a card beforehand or a
    /// record afterwards.
    /// Arms the one-shot summary for this conversation.
    ///
    /// Titling is deliberately once per conversation, not per run: a chat list
    /// whose rows rewrite themselves as the conversation grows is harder to scan
    /// than one whose rows stay put. `titledConversationIDs` is what makes the
    /// second run a no-op even though every run re-arms the hook.
    private func scheduleTitle(
        for conversation: ConversationModel, isPlanning: Bool, operationID: String,
        memoryToken: UUID?, reviewModel: (any AgentModelCompleting)?
    ) {
        let conversationID = conversation.id.uuidString.lowercased()
        conversation.runDidFinish = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            let state = conversation.runState
            logger.log(
                level: state == .completed ? .info : state == .cancelled ? .warning : .error,
                "agent.run.finished",
                metadata: [
                    "conversation_id": "\(conversationID)", "operation_id": "\(operationID)",
                    "outcome": "\(state.rawValue)", "stage": "finished",
                ])
            guard let context = Self.titleContext(for: conversation),
                !titledConversationIDs.contains(conversation.id)
            else { return }
            titledConversationIDs.insert(conversation.id)
            Task { [weak self, weak conversation] in
                guard let self else { return }
                guard let title = try? await title(context),
                    let conversation
                else { return }
                do {
                    try await agentRunRepository.setTitle(title, conversationID: conversation.id)
                    conversation.title = title
                } catch {
                    titledConversationIDs.remove(conversation.id)
                }
            }
        }
        if !isPlanning, let memoryToken, let memory {
            let historyEpoch = memory.learningEpoch(for: conversation.id)
            if let reviewModel {
                for (index, message) in conversation.transcript.enumerated() where message.role == .user {
                    memory.considerCorrection(
                        conversationID: conversation.id, message: message,
                        context: Array(conversation.transcript.prefix(index + 1).suffix(6)),
                        model: reviewModel, sessionToken: memoryToken, historyEpoch: historyEpoch)
                }
            }
            conversation.memoryUserAccepted = { [weak conversation] message, context in
                guard let conversation, let reviewModel else { return }
                memory.considerCorrection(
                    conversationID: conversation.id, message: message, context: context,
                    model: reviewModel, sessionToken: memoryToken, historyEpoch: historyEpoch)
            }
            conversation.memoryToolBatchFinished = { [weak conversation] toolEvents, messages in
                guard let conversation else { return }
                Task {
                    await memory.recordActivity(
                        conversationID: conversation.id, userMessageIDs: [],
                        toolInvocations: toolEvents, messages: messages, model: reviewModel,
                        sessionToken: memoryToken, historyEpoch: historyEpoch)
                }
            }
            conversation.memoryRunFinished = { [weak conversation] _, userIDs, toolEvents, messages in
                guard let conversation else { return }
                Task {
                    await memory.recordActivity(
                        conversationID: conversation.id, userMessageIDs: userIDs,
                        toolInvocations: toolEvents, messages: messages, model: reviewModel,
                        sessionToken: memoryToken, historyEpoch: historyEpoch)
                }
            }
        } else {
            conversation.memoryUserAccepted = nil
            conversation.memoryRunFinished = nil
            conversation.memoryToolBatchFinished = nil
        }
    }

    private func memoryReviewModel(_ conversation: ConversationModel) -> (any AgentModelCompleting)? {
        guard memory?.isEnabled == true else { return nil }
        guard let resolved = ai.resolve(conversation: memory?.reviewModel ?? conversation.model),
            let secret = ai.modelSecret(for: resolved.provider)
        else { return nil }
        return AgentProviderClient(
            provider: resolved.provider, model: resolved.model, secret: secret,
            reasoning: conversation.reasoningEffort)
    }

    /// The opening exchange, if this conversation has one worth naming.
    ///
    /// Read from `transcript`, not `messages`. A run that failed puts its reason
    /// in the visible list alone, so gating on `messages` would happily title a
    /// conversation "The Chat model has no available credential."
    ///
    /// Gated on there being a reply rather than on the run having *completed*,
    /// so a run the user stopped after a full first answer still gets a title
    /// instead of staying labelled by its opening line forever.
    public static func titleContext(for conversation: ConversationModel) -> ConversationTitleContext? {
        guard conversation.title == nil,
            let firstUser = conversation.transcript.first(where: { $0.role == .user }),
            let assistant = conversation.transcript.first(where: {
                $0.role == .assistant && !$0.text.isEmpty
            })?.text
        else { return nil }
        let user =
            firstUser.text.isEmpty
            ? firstUser.images.first?.label
                ?? firstUser.contextAttachments.first?.label
                ?? ""
            : firstUser.text
        guard !user.isEmpty else { return nil }
        return ConversationTitleContext(
            firstUserMessage: user, firstAssistantMessage: assistant
        )
    }

}
