import AgentKit
import Foundation
import TermindDomain

/// One runtime assembly and compaction policy for both app surfaces.
@MainActor
public final class AssistantExecutionController {
    public typealias RegistryFactory =
        @MainActor (ConversationModel, AIModel, ModelProvider, AgentSkillCatalog, AgentEventChannel, Bool) ->
        AgentToolRegistry
    private let ai: AIConfigurationModel
    private let skills: SkillLibraryModel
    private let agentRunRepository: any AgentRunPersisting
    private let authorize: @MainActor () -> Bool
    private let makeRegistry: RegistryFactory
    private let title: @MainActor (ConversationTitleContext) async throws -> String
    private let agentCompaction = AgentCompactionService()
    private let guardianSessions = GuardianSessionStore()
    private var titledConversationIDs = Set<UUID>()
    private var preparationGeneration: UInt64 = 0
    private var preparing = Set<UUID>()

    public func cancelPendingRuns() { preparationGeneration &+= 1 }

    public init(
        ai: AIConfigurationModel, skills: SkillLibraryModel, repository: any AgentRunPersisting,
        authorize: @escaping @MainActor () -> Bool, makeRegistry: @escaping RegistryFactory,
        title: @escaping @MainActor (ConversationTitleContext) async throws -> String
    ) {
        self.ai = ai
        self.skills = skills
        agentRunRepository = repository
        self.authorize = authorize
        self.makeRegistry = makeRegistry
        self.title = title
    }

    public func sendAgentDraft(
        _ conversation: ConversationModel,
        context: SessionContext = .none,
        includesTerminalSuggestion: Bool = false
    ) {
        guard authorize() else { return }
        let draft = conversation.composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversation.canSendDraft, !conversation.isArchived, !conversation.isStreaming,
            !conversation.isCompacting, !conversation.isHistoryChanging,
            conversation.composer.pendingAttachments.isEmpty,
            preparing.insert(conversation.id).inserted
        else { return }
        let generation = preparationGeneration
        // The *returned* text, not `draft`: attachments are folded in there, and
        // running on the pre-fold string would show the model a turn that does
        // not match the one the conversation recorded.
        let prompt = conversation.appendUserTurnContent(
            draft,
            contextSnapshot: contextSnapshot(
                for: conversation, context: context, includesTerminalSuggestion: includesTerminalSuggestion))
        conversation.composer.draft = ""
        // Compaction happens *after* the turn is recorded and before the run,
        // so the message the user just typed is inside the kept window rather
        // than being the first thing summarized away. When nothing needs
        // compacting this is a synchronous check that starts the run in the same
        // tick, which is what keeps the composer feeling immediate.
        Task { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            defer { preparing.remove(conversation.id) }
            await compactIfNeeded(conversation)
            guard generation == preparationGeneration, !Task.isCancelled else {
                do {
                    try await agentRunRepository.save(
                        AgentRunSnapshot(
                            conversationID: conversation.id, state: .interrupted,
                            permissionMode: ai.resolve(conversation: conversation.permissionMode),
                            messages: conversation.transcript, finishedAt: .now))
                    conversation.handle(.runState(.interrupted))
                } catch {
                    conversation.messages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
                }
                return
            }
            startAgentRun(
                conversation, promptID: prompt.id, prompt: prompt.text,
                authoredPrompt: prompt.authoredText, promptImages: prompt.images,
                promptContextAttachments: prompt.contextAttachments, context: context,
                includesTerminalSuggestion: includesTerminalSuggestion
            )
        }
    }

    public func startAgentRun(
        _ conversation: ConversationModel,
        promptID: UUID? = nil,
        prompt: String? = nil,
        authoredPrompt: String? = nil,
        promptImages: [AgentImageAttachment]? = nil,
        promptContextAttachments: [AgentContextAttachment]? = nil,
        context: SessionContext? = nil,
        includesTerminalSuggestion: Bool = false
    ) {
        guard authorize() else { return }
        guard !conversation.isStreaming, !conversation.isArchived, !conversation.isHistoryChanging else { return }
        let lastUserTurn = conversation.transcript.last(where: { $0.role == .user })
        let userPrompt =
            prompt
            ?? lastUserTurn?.text
            ?? ""
        let userImages =
            promptImages
            ?? lastUserTurn?.images
            ?? []
        let userContextAttachments =
            promptContextAttachments
            ?? lastUserTurn?.contextAttachments
            ?? []
        guard !userPrompt.isEmpty || !userImages.isEmpty || !userContextAttachments.isEmpty
        else { return }
        guard let chat = ai.resolve(conversation: conversation.model) else {
            recordFailedRun(
                conversation,
                promptID: promptID ?? lastUserTurn?.id ?? UUID(),
                prompt: userPrompt,
                authoredPrompt: authoredPrompt ?? lastUserTurn?.authoredText,
                images: userImages,
                contextAttachments: userContextAttachments,
                reason: String(localized: "No Chat model is configured.")
            )
            return
        }
        guard let secret = ai.secret(for: chat.provider.effectiveCredentialRef), !secret.isEmpty else {
            recordFailedRun(
                conversation,
                promptID: promptID ?? lastUserTurn?.id ?? UUID(),
                prompt: userPrompt,
                authoredPrompt: authoredPrompt ?? lastUserTurn?.authoredText,
                images: userImages,
                contextAttachments: userContextAttachments,
                reason: String(localized: "The Chat model has no available credential.")
            )
            return
        }

        let mode = ai.resolve(conversation: conversation.permissionMode)
        let nativeSearch =
            ai.webSearch.isEnabled && ai.webSearch.prefersBuiltIn
            && chat.provider.supportsNativeWebSearch(model: chat.model)
        let model = AgentProviderClient(
            provider: chat.provider, model: chat.model, secret: secret,
            reasoning: conversation.reasoningEffort,
            webSearch: nativeSearch, promptCacheKey: conversation.id.uuidString
        )
        // One channel for the whole run, shared by everything that publishes
        // into it. The broker used to raise its review events through a closure
        // of its own, each wrapped in an unstructured `Task` — so a review's
        // events had no defined order against the tool events they belong
        // between, and its durable writes had no defined order against
        // anything. See `AgentEventChannel`.
        let channel = AgentEventChannel(repository: agentRunRepository)

        // Read once, here, for the reason `isPlanning` below is: a run's posture
        // is fixed when it starts, so enabling a skill while the agent is
        // thinking must not change what this run was told it had. Empty when the
        // model cannot call tools, which is what keeps the catalog block from
        // naming a tool this run was never given.
        let skillCatalog =
            chat.model.abilities.contains(.toolCall)
            ? skills.catalog : AgentSkillCatalog()

        let registry = makeRegistry(
            conversation, chat.model, chat.provider, skillCatalog, channel, includesTerminalSuggestion)
        let interaction = WeakAgentUserInteraction(conversation)
        let services = AgentToolServices()
            .setting(interaction.sshInteraction, for: .sshInteraction)
        let guardianServices = AgentToolServices()
            .setting(AgentSSHInteraction.unavailable, for: .sshInteraction)
        let reviewer: (any GuardianReviewing)? = {
            guard mode == .approveForMe, let review = ai.resolve(.guardian) else { return nil }
            guard let reviewSecret = ai.secret(for: review.provider.effectiveCredentialRef),
                !reviewSecret.isEmpty
            else { return nil }
            let reasoning = GuardianClient.preferredReasoning(
                model: review.model, provider: review.provider
            )
            let reviewTools =
                review.model.abilities.contains(.toolCall)
                ? registry : AgentToolRegistry([])
            return GuardianClient(
                model: AgentProviderClient(
                    provider: review.provider, model: review.model, secret: reviewSecret,
                    reasoning: reasoning,
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
        let frozenContext =
            lastUserTurn?.contextSnapshot
            ?? contextSnapshot(
                for: conversation, context: context ?? .none, includesTerminalSuggestion: includesTerminalSuggestion)
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
        configuration.contextSnapshot = { session, planning in
            AgentTurnContextSnapshot(
                sessionContext: session, skillCatalog: skillCatalog.isEmpty ? nil : skillCatalog.catalogBlock,
                planContract: planning ? TermindAgentPolicy.planContract : nil)
        }
        configuration.contextPipeline = { sessionContext, promptID, planning in
            AgentContextPipeline.chat(
                sessionContext: sessionContext, before: promptID,
                isPlanning: planning, skills: skillCatalog,
                planContract: TermindAgentPolicy.planContract
            )
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
        // withholds the probe when the setting is off, and `context` is the same
        // value the chips were drawn from — so what is shown and what is sent
        // cannot disagree.
        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id,
                promptID: promptID ?? lastUserTurn?.id ?? UUID(), prompt: userPrompt,
                authoredPrompt: authoredPrompt ?? lastUserTurn?.authoredText,
                promptImages: userImages,
                promptContextAttachments: userContextAttachments,
                permissionMode: mode, isPlanning: isPlanning,
                systemPrompt: TermindAgentPolicy.systemPrompt,
                priorMessages: conversation.pendingPriorMessages,
                authorizationEvidence: GuardianEvidence.collect(from: conversation.transcript),
                sessionContext: frozenContext.sessionContext, contextSnapshot: frozenContext
            ))
        scheduleTitle(for: conversation)
    }

    private func recordFailedRun(
        _ conversation: ConversationModel,
        promptID: UUID,
        prompt: String,
        authoredPrompt: String?,
        images: [AgentImageAttachment],
        contextAttachments: [AgentContextAttachment],
        reason: String
    ) {
        var messages = conversation.pendingPriorMessages
        if !messages.contains(where: { $0.id == promptID }) {
            messages.append(
                AgentTranscriptMessage(
                    id: promptID, role: .user, text: prompt,
                    authoredText: authoredPrompt, images: images,
                    contextAttachments: contextAttachments,
                    contextSnapshot: conversation.transcript.first(where: { $0.id == promptID })?.contextSnapshot
                ))
        }
        let now = Date.now
        let snapshot = AgentRunSnapshot(
            conversationID: conversation.id, state: .failed,
            permissionMode: ai.resolve(conversation: conversation.permissionMode),
            messages: messages, startedAt: now, finishedAt: now,
            failure: reason
        )
        conversation.recordFailedRun(snapshot)
        Task { [agentRunRepository] in try? await agentRunRepository.save(snapshot) }
    }

    public func contextSnapshot(
        for conversation: ConversationModel, context: SessionContext, includesTerminalSuggestion: Bool
    ) -> AgentTurnContextSnapshot {
        let catalog =
            ai.resolve(conversation: conversation.model)?.model.abilities.contains(.toolCall) == true
            ? skills.catalog : AgentSkillCatalog()
        return AgentTurnContextSnapshot(
            sessionContext: context.modelContext,
            skillCatalog: catalog.isEmpty ? nil : catalog.catalogBlock,
            planContract: conversation.isPlanning ? TermindAgentPolicy.planContract : nil,
            toolAvailability: ["terminal_suggest": includesTerminalSuggestion]
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
        guard !conversation.isStreaming, !conversation.isCompacting else { return false }
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

    /// Compacts before a run when the conversation is close to the window.
    ///
    /// Threshold only. Recovering a turn that has *already* overflowed means
    /// recognising four providers' distinct context-length errors, which is its
    /// own piece of work — this is what keeps a conversation from getting there.
    private func compactIfNeeded(_ conversation: ConversationModel) async {
        guard let usage = conversation.usage else { return }
        let window = ai.resolve(conversation: conversation.model)?.model.contextLength
        guard
            AgentCompaction.shouldCompact(
                contextTokens: usage.contextTokens, contextWindow: window,
                reserveTokens: compactionBudget.reserveTokens
            )
        else { return }
        await compact(conversation, isManual: false)
    }

    /// Resolves the Chat model with reasoning clamped off, like titling does.
    ///
    /// Summarizing is not a task that improves with a thinking budget, and this
    /// runs on the user's own key at the moment their conversation is already
    /// expensive.
    private func compactionModel() -> (any AgentModelCompleting)? {
        guard let resolved = ai.resolve(.chat) else { return nil }
        guard let secret = ai.secret(for: resolved.provider.effectiveCredentialRef), !secret.isEmpty
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
    private func scheduleTitle(for conversation: ConversationModel) {
        conversation.runDidFinish = { [weak self, weak conversation] in
            guard let self, let conversation,
                let context = Self.titleContext(for: conversation),
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
