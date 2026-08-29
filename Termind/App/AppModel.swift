import Foundation

/// The ways a host can be opened. Centralised so the sidebar, the workspace bar's `+`
/// menu, and the menu bar all take the same code path — including the bookkeeping
/// (mark as recently used, flip the status dot) that is easy to forget in one of
/// three places.
/// There is no "open into the current split" here, deliberately. A Workspace is
/// assembled from things already open — drag one workspace onto another — so opening a
/// host never has to know about layout, and a host you have never opened can
/// never appear welded into whatever workspace happened to be front.
/// Where a batch of hosts lands: a workspace each, or one Workspace holding all of
/// them. Bringing a dozen machines up is usually so you can *watch* them, and
/// watching them means having them on screen at once.
nonisolated enum BatchLayout: Hashable, Sendable {
    case separateWorkspaces
    case oneWorkspace
}

nonisolated enum HostOpenTarget: Hashable, Sendable {
    case sshSession
    case sftpSession
}

/// A destination typed into Welcome. The username belongs to this one attempt
/// until the user explicitly saves it; keeping it beside the Host avoids
/// inventing a persisted Identity just because somebody typed `user@host`.
nonisolated struct QuickConnectTarget: Hashable, Sendable {
    var host: Host
    var username: String?

    var loginAddress: String {
        guard let username, !username.isEmpty else { return host.displayAddress }
        return "\(username)@\(host.displayAddress)"
    }
}

/// App-wide state shared by every window: the saved hosts, and the one code path
/// for opening them.
///
/// Everything the user can have in a *different* state in a second window —
/// workspaces, sidebar selection, search text, Sidebar visibility — lives on
/// `WindowModel` instead.
@Observable
final class AppModel {
    private final class WeakWindow {
        weak var value: WindowModel?
        init(_ value: WindowModel) { self.value = value }
    }

    private let hosts: HostLibraryModel
    let proAccess: ProAccessController
    var hostLibrary: HostLibraryModel { hosts }
    let credentials: CredentialLibraryModel
    let snippets: SnippetLibraryModel
    let forwardings: ForwardingLibraryModel
    let transfers: TransferLibraryModel
    let commandHistory: CommandHistoryModel
    let sftpHistory: SFTPHistoryModel
    let connectionHistory: ConnectionHistoryModel
    private let externalToolCalls: ToolAuditModel
    var toolAudit: ToolAuditModel { externalToolCalls }
    let externalAuthentication: ExternalAuthCoordinator
    let mcpServer: MCPServerController
    let commands = AppCommandRegistry()
    let onboarding: OnboardingController
    let connections: RemoteConnectionCoordinator
    let serialPorts: any SerialPortServing
    let hostRepository: any HostRepository
    let vaultSync: VaultSyncCoordinator?
    let forwarding: PortForwardingController
    let sftpTransfers: SFTPTransferCoordinator
    /// Providers, models, role assignments, MCP servers.
    ///
    /// Its own store rather than more fields on `HostLibraryModel`: that one is about
    /// machines you connect to, this one about endpoints you spend a key at.
    /// See `AIConfigurationModel`.
    private let ai: AIConfigurationModel
    var aiConfiguration: AIConfigurationModel { ai }
    let commandGenerator: CommandGeneratorController
    /// Names conversations for the chat list. Held as the protocol, not the
    /// concrete controller, so a test can watch the trigger without a provider.
    var conversationTitles: any ConversationTitling
    /// One app-wide microphone owner. Keeping this above individual composers
    /// prevents two windows from installing competing audio taps.
    let speechTranscription: SpeechTranscriptionCoordinator
    /// The one set of conversations every window navigates. See
    /// `AssistantConversationStore`.
    private let assistantConversations = AssistantConversationStore()
    private let agentRunRepository: any AgentRunPersisting
    private let agentHosts: AgentHostResolver
    private let agentConnections: AgentConnectionPool
    private let agentAuthentication: AgentSSHAuthenticationRegistry
    /// Commands that outlived the turn that started them. App-wide rather than
    /// per-run, because a handle taken in one turn is answered in a later one
    /// and a run ending is not a reason to stop a deploy.
    private let agentBackgroundCommands = AgentBackgroundCommands()
    private let agentCompaction = AgentCompactionService()
    private let outboxRunner: OutboxRunner?
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var deletedAgentConversationIDs = Set<UUID>()
    /// Conversations already handed to the summarizer. Titling is once per
    /// conversation, and every run re-arms the hook that would do it.
    private var titledConversationIDs = Set<UUID>()

    init(
        hosts: HostLibraryModel, ai: AIConfigurationModel = AIConfigurationModel(),
        commandHistory: CommandHistoryModel = CommandHistoryModel(),
        sftpHistory: SFTPHistoryModel = SFTPHistoryModel(),
        connectionHistory: ConnectionHistoryModel = ConnectionHistoryModel(),
        externalToolCalls: ToolAuditModel = ToolAuditModel(),
        dependencies: AppDependencies? = nil,
        speechTranscription: SpeechTranscriptionCoordinator? = nil,
        proAccess: ProAccessController = .unrestrictedForTesting(),
        onboarding: OnboardingController = OnboardingController()
    ) {
        let dependencies = dependencies ?? .inMemory(hosts: hosts.hosts, groups: hosts.groups)
        let connectionCoordinator = dependencies.connectionCoordinator
        self.hosts = hosts
        self.proAccess = proAccess
        self.onboarding = onboarding
        credentials = CredentialLibraryModel(library: hosts)
        snippets = SnippetLibraryModel(library: hosts)
        forwardings = ForwardingLibraryModel(library: hosts)
        transfers = TransferLibraryModel(library: hosts)
        self.commandHistory = commandHistory
        self.sftpHistory = sftpHistory
        self.connectionHistory = connectionHistory
        self.externalToolCalls = externalToolCalls
        externalAuthentication = ExternalAuthCoordinator()
        connections = connectionCoordinator
        serialPorts = dependencies.serialPortService
        agentRunRepository = dependencies.agentRunRepository ?? InMemoryAgentRunRepository()
        agentHosts = AgentHostResolver(
            store: hosts,
            discoverHostKey: { hostID, host, port, proxy, jumps in
                try await SSHSessionActor.discoverHostKey(
                    hostID: hostID, host: host, port: port,
                    proxy: proxy, jumps: jumps
                )
            }
        )
        let agentHostResolver = agentHosts
        agentAuthentication = AgentSSHAuthenticationRegistry(resolver: agentHostResolver)
        agentConnections = AgentConnectionPool(
            configuration: { try await agentHostResolver.configuration(for: $0) },
            routeFingerprint: { try await agentHostResolver.routeFingerprint(for: $0) },
            openExec: { try await connectionCoordinator.connectExec(using: $0) },
            openSFTP: { try await connectionCoordinator.connectSFTP(using: $0) }
        )
        hostRepository = dependencies.hostRepository
        vaultSync = dependencies.vaultSync
        forwarding = PortForwardingController(hosts: hosts)
        sftpTransfers = SFTPTransferCoordinator(
            store: hosts,
            clientFactory: { connectionCoordinator.makeSFTPClient() }
        )
        self.ai = ai
        commandGenerator = CommandGeneratorController(ai: ai)
        conversationTitles = ConversationTitleController(ai: ai)
        self.speechTranscription =
            speechTranscription
            ?? SpeechTranscriptionCoordinator(
                service: AppleSpeechTranscriptionService(audioInput: MacOSSpeechAudioInput())
            )
        outboxRunner = dependencies.outboxRunner
        mcpServer = MCPServerController(
            ai: ai, hosts: agentHosts, connections: agentConnections,
            authentication: agentAuthentication, background: agentBackgroundCommands,
            externalAuthentication: externalAuthentication, history: externalToolCalls,
            canUsePro: { proAccess.canUse(.mcpServer) },
            requestPro: { proAccess.require(.mcpServer) }
        )
        agentHosts.configureTemporaryTargets(
            targets: { [weak self] in self?.temporaryAgentTargets() ?? [] },
            configuration: { [weak self] hostID in
                self?.temporaryAgentConfiguration(for: hostID)
            }
        )
        hosts.willDeleteHost = { [weak forwarding, agentConnections] hostID, ruleIDs in
            forwarding?.stop(ruleIDs)
            // Not a `HostDeletionOutbox` step like the others: a live socket
            // cannot outlive the process, so there is nothing to replay after a
            // crash and nothing to make durable.
            Task { await agentConnections.disconnect(hostID: hostID) }
        }
        hosts.willDeletePortForwardings = { [weak forwarding] ruleIDs in
            forwarding?.stop(ruleIDs)
        }
        hosts.didPersistCore = { [weak repository = dependencies.hostRepository] in
            try? repository?.refresh()
        }
        hosts.didRecordVaultChanges = { [weak vaultSync = dependencies.vaultSync] mutations in
            vaultSync?.noteLocalChanges(mutations)
        }
        if let repository = dependencies.hostRepository as? SwiftDataHostRepository {
            repository.didRecordVaultChanges = { [weak vaultSync = dependencies.vaultSync] mutations in
                vaultSync?.noteLocalChanges(mutations)
            }
        }
        if let outboxRunner {
            outboxRunner.register(
                RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.closeWorkspaces) {
                    [weak self] deletion in
                    self?.closeWorkspaces(for: deletion.hostID)
                }
            )
            outboxRunner.register(
                RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.cancelTransfers) {
                    [weak self] deletion in
                    self?.sftpTransfers.cancelAll(for: deletion.hostID)
                }
            )
            outboxRunner.register(
                RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.stopForwardings) {
                    [weak self] deletion in
                    self?.forwarding.stop(deletion.forwardingRuleIDs)
                }
            )
            outboxRunner.register(
                RepositoryHostDeletionHandler(
                    handlerID: HostDeletionOutbox.clearReferences,
                    repository: hostRepository
                )
            )
            outboxRunner.register(
                RepositoryHostDeletionHandler(
                    handlerID: HostDeletionOutbox.finalize,
                    repository: hostRepository
                )
            )
            outboxRunner.start()
        }
        vaultSync?.didApplyRemote = { [weak self] snapshot, keys in
            self?.applyRemoteVaultSnapshot(snapshot, changedKeys: keys)
        }
        if proAccess.canUse(.vaultSync) { vaultSync?.start() }
    }

    func reconcileProAccess() {
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            mcpServer.resumeForProAccess()
        } else {
            vaultSync?.pause()
        }
        if !proAccess.canUse(.mcpServer), mcpServer.isEnabled {
            mcpServer.suspendForProAccess()
        }
    }

    private func applyRemoteVaultSnapshot(
        _ snapshot: VaultSnapshot, changedKeys: Set<VaultRecordKey>
    ) {
        let changedHostIDs = Set(changedKeys.filter { $0.kind == .host }.map(\.id))
        let changedRuleIDs = Set(changedKeys.filter { $0.kind == .portForwarding }.map(\.id))
        let nextHostIDs = Set(snapshot.hosts.map(\.id))

        for hostID in changedHostIDs {
            let oldHost = hosts.host(hostID)
            let newHost = snapshot.hosts.first { $0.id == hostID }
            let routeChanged = oldHost.map { old in
                newHost.map {
                    old.host != $0.host || old.port != $0.port
                        || old.identityID != $0.identityID || old.jumpHostID != $0.jumpHostID
                        || old.proxy != $0.proxy
                } ?? true
            } ?? false
            if routeChanged {
                hosts.willDeleteHost?(hostID, hosts.portForwardings(for: hostID).map(\.id))
            }
            if oldHost != nil, !nextHostIDs.contains(hostID) {
                closeWorkspaces(for: hostID)
                sftpTransfers.cancelAll(for: hostID)
                commandHistory.clear(for: hostID)
                sftpHistory.clear(for: hostID)
                connectionHistory.clear(for: hostID)
            }
        }
        if !changedRuleIDs.isEmpty { forwarding.stop(Array(changedRuleIDs)) }
        hosts.replacePersistedSnapshot(snapshot)
    }

    func sendAgentDraft(
        _ conversation: ConversationModel,
        context: SessionContext = .none,
        includesTerminalSuggestion: Bool = false
    ) {
        guard proAccess.require(.assistant) else { return }
        let draft = conversation.composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversation.canSendDraft else { return }
        // The *returned* text, not `draft`: attachments are folded in there, and
        // running on the pre-fold string would show the model a turn that does
        // not match the one the conversation recorded.
        let prompt = conversation.appendUserTurnContent(draft)
        conversation.composer.draft = ""
        // Compaction happens *after* the turn is recorded and before the run,
        // so the message the user just typed is inside the kept window rather
        // than being the first thing summarized away. When nothing needs
        // compacting this is a synchronous check that starts the run in the same
        // tick, which is what keeps the composer feeling immediate.
        Task { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            await compactIfNeeded(conversation)
            startAgentRun(
                conversation, promptID: prompt.id, prompt: prompt.text,
                authoredPrompt: prompt.authoredText, promptImages: prompt.images,
                promptContextAttachments: prompt.contextAttachments, context: context,
                includesTerminalSuggestion: includesTerminalSuggestion
            )
        }
    }

    func startAgentRun(
        _ conversation: ConversationModel,
        promptID: UUID? = nil,
        prompt: String? = nil,
        authoredPrompt: String? = nil,
        promptImages: [AgentImageAttachment]? = nil,
        promptContextAttachments: [AgentContextAttachment]? = nil,
        context: SessionContext = .none,
        includesTerminalSuggestion: Bool = false
    ) {
        guard proAccess.require(.assistant) else { return }
        let lastUserTurn = conversation.transcript.last(where: { $0.role == .user })
        let userPrompt =
            prompt
            ?? lastUserTurn?.text
            ?? ""
        let userImages = promptImages
            ?? lastUserTurn?.images
            ?? []
        let userContextAttachments = promptContextAttachments
            ?? lastUserTurn?.contextAttachments
            ?? []
        guard !userPrompt.isEmpty || !userImages.isEmpty || !userContextAttachments.isEmpty
        else { return }
        guard let chat = ai.resolve(conversation: conversation.model) else {
            conversation.messages.append(
                ChatMessage(
                    role: .assistant, text: String(localized: "No Chat model is configured.")
                ))
            return
        }
        let credentialRef =
            chat.provider.usesVertex && chat.provider.kind == .google
            ? chat.provider.vertex.credentialRef : chat.provider.credentialRef
        guard let secret = ai.secret(for: credentialRef), !secret.isEmpty else {
            conversation.messages.append(
                ChatMessage(
                    role: .assistant, text: String(localized: "The Chat model has no available credential.")
                ))
            return
        }

        let mode = ai.resolve(conversation: conversation.permissionMode)
        let searchPlan = webSearchPlan(model: chat.model, provider: chat.provider)
        let model = AgentProviderClient(
            provider: chat.provider, model: chat.model, secret: secret,
            reasoning: conversation.reasoningEffort,
            webSearch: searchPlan.isNative
        )
        let reviewer: (any SecurityReviewing)? = {
            guard mode == .approveForMe, let review = ai.resolve(.securityReview) else { return nil }
            let ref =
                review.provider.usesVertex && review.provider.kind == .google
                ? review.provider.vertex.credentialRef : review.provider.credentialRef
            guard let reviewSecret = ai.secret(for: ref), !reviewSecret.isEmpty else { return nil }
            let reasoning = SecurityReviewClient.preferredReasoning(
                model: review.model, provider: review.provider
            )
            return SecurityReviewClient(
                model: AgentProviderClient(
                    provider: review.provider, model: review.model, secret: reviewSecret,
                    reasoning: reasoning
                ))
        }()
        // One channel for the whole run, shared by everything that publishes
        // into it. The broker used to raise its review events through a closure
        // of its own, each wrapped in an unstructured `Task` — so a review's
        // events had no defined order against the tool events they belong
        // between, and its durable writes had no defined order against
        // anything. See `AgentEventChannel`.
        let channel = AgentEventChannel(repository: agentRunRepository)
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
            event: channel.emit
        )

        var registry = AgentToolRegistry([AnyAgentTool]())
        if chat.model.abilities.contains(.toolCall) {
            // One workspace per conversation, not per run: a file staged before the
            // user interrupted, or before they typed a follow-up, is still there for
            // the run that answers them. Isolation comes from the scope directory
            // being keyed by conversation, so one chat can never read what another
            // pulled off a host.
            let scratch = AgentScratchWorkspace(conversationID: conversation.id)
            // One client for both, rather than two default-constructed ones: `fetch`
            // and `scratch_fetch` read the same web the same way and differ only in
            // where the page ends up.
            let web = ScrubberWebClient()
            // Both write through the one ordered channel the rest of the run
            // uses, rather than reaching into the conversation directly: a tool
            // that touched `@Observable` state from a task group would be
            // mutating the UI from off the main actor.
            let servers = ai.mcpServers.filter(\.isEnabled).map { server in
                (server: server, bearerToken: ai.secret(for: server.credentialRef))
            }
            // Local definitions are registered once in the static catalog;
            // discovered MCP definitions join the same resolved registry after
            // them, so a remote name can never shadow a built-in.
            registry = AgentToolCatalog.registry(environment: AgentToolEnvironment(
                hosts: agentHosts, connections: agentConnections,
                authentication: agentAuthentication,
                background: agentBackgroundCommands, web: web,
                search: searchPlan.local,
                includesTerminalSuggestion: includesTerminalSuggestion,
                workspace: scratch,
                tasks: AgentTaskList { channel.emit(.tasksUpdated($0)) },
                plans: AgentPlanRecorder { channel.emit(.planPresented($0)) },
                mcpServers: servers
            ))
        }
        // The one place the resolved tool set exists. Recorded on the
        // conversation so the context gauge can account for the schemas without
        // rebuilding a registry on every keystroke.
        conversation.noteToolSchemas(registry.descriptors)
        // Read once, here: the posture a run enforces is the one it started
        // under, and the user is free to leave plan mode while it is thinking.
        let isPlanning = conversation.isPlanning
        let runtime = AgentRuntime(
            model: model, registry: registry,
            approval: approval,
            repository: agentRunRepository,
            userInteraction: WeakAgentUserInteraction(conversation),
            hooks: [AgentPlanModeHook(isPlanning: isPlanning)],
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
                priorMessages: conversation.pendingPriorMessages,
                sessionContext: context
            ))
        scheduleTitle(for: conversation)
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
    func compact(
        _ conversation: ConversationModel,
        instructions: String = "",
        isManual: Bool = true
    ) async -> Bool {
        guard proAccess.require(.assistant) else { return false }
        guard !conversation.isStreaming, !conversation.isCompacting else { return false }
        conversation.beginCompaction()
        guard let span = conversation.compactionSpan(keepRecentTokens: keepRecentTokens)
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
                span.summarize, instructions: instructions, model: model
            )
            conversation.applyCompaction(summary: summary, cut: span.cut)
            conversation.endCompaction()
            return true
        } catch {
            conversation.failCompaction(error.localizedDescription)
            return false
        }
    }

    /// Compacts before a run when the conversation is close to the window.
    ///
    /// Threshold only. Recovering a turn that has *already* overflowed means
    /// recognising four providers' distinct context-length errors, which is its
    /// own piece of work — this is what keeps a conversation from getting there.
    private func compactIfNeeded(_ conversation: ConversationModel) async {
        guard SettingsKey.isAutoCompactEnabled else { return }
        guard let usage = conversation.usage else { return }
        let window = ai.resolve(conversation: conversation.model)?.model.contextLength
        guard
            AgentCompaction.shouldCompact(
                contextTokens: usage.contextTokens, contextWindow: window,
                reserveTokens: reserveTokens
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
        let credentialRef =
            resolved.provider.usesVertex && resolved.provider.kind == .google
            ? resolved.provider.vertex.credentialRef : resolved.provider.credentialRef
        guard let secret = ai.secret(for: credentialRef), !secret.isEmpty else { return nil }
        let reasoning = ModelCapabilityResolver.reasoning(
            model: resolved.model, provider: resolved.provider
        ).clamp(.off)
        return AgentProviderClient(
            provider: resolved.provider, model: resolved.model, secret: secret,
            reasoning: reasoning
        )
    }

    private var keepRecentTokens: Int {
        SettingsKey.compactionKeepRecent
    }

    private var reserveTokens: Int {
        SettingsKey.compactionReserve
    }

    /// Exactly one path is ever live. Offering both would put two tools in
    /// front of the model for one job and leave it to guess which, and the
    /// guess would decide whether the search shows up as a card beforehand or a
    /// record afterwards.
    private func webSearchPlan(
        model: AIModel, provider: ModelProvider
    ) -> (isNative: Bool, local: ScrubberWebClient?) {
        guard SettingsKey.isWebSearchEnabled else { return (false, nil) }
        if SettingsKey.isBuiltInWebSearchEnabled,
            provider.supportsNativeWebSearch(model: model)
        {
            return (true, nil)
        }
        return (false, ScrubberWebClient())
    }

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
                guard let title = try? await conversationTitles.summarize(context),
                    let conversation
                else { return }
                conversation.title = title
                try? await agentRunRepository.setTitle(title, conversationID: conversation.id)
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
    static func titleContext(for conversation: ConversationModel) -> ConversationTitleContext? {
        guard conversation.title == nil,
            let firstUser = conversation.transcript.first(where: { $0.role == .user }),
            let assistant = conversation.transcript.first(where: {
                $0.role == .assistant && !$0.text.isEmpty
            })?.text
        else { return nil }
        let user = firstUser.text.isEmpty
            ? firstUser.images.first?.label
                ?? firstUser.contextAttachments.first?.label
                ?? ""
            : firstUser.text
        guard !user.isEmpty else { return nil }
        return ConversationTitleContext(
            firstUserMessage: user, firstAssistantMessage: assistant
        )
    }

    func registerWindow(_ window: WindowModel) {
        windows = windows.filter { $0.value.value != nil }
        windows[ObjectIdentifier(window)] = WeakWindow(window)
        window.commandHistoryStore = commandHistory
        window.sftpHistoryStore = sftpHistory
        window.assistantLibrary.adopt(assistantConversations)
        window.assistantCommands = AssistantConversationCommands(
            delete: { [weak self] id in self?.deleteAgentConversation(id) },
            togglePin: { [weak self, weak window] id in
                self?.togglePin(id, reportingTo: window)
            },
            move: { [weak self, weak window] id, pinned, nextID in
                self?.moveConversation(id, toPinned: pinned, before: nextID, reportingTo: window)
            },
            rename: { [weak self, weak window] id, title in
                self?.renameConversation(id, to: title, reportingTo: window)
            },
            archive: { [weak self, weak window] id, archived in
                self?.setArchived(id, archived: archived, reportingTo: window)
            },
            fork: { [weak self, weak window] id, messageID, inSidebar in
                self?.forkConversation(id, at: messageID, selectingIn: window, inSidebar: inSidebar)
            },
            edit: { [weak self, weak window] id, messageID, text, context, includes in
                self?.editConversation(
                    id, messageID: messageID, text: text, context: context,
                    includesTerminalSuggestion: includes, reportingTo: window
                )
            }
        )
        Task { [agentRunRepository, weak window, weak self] in
            guard let restored = try? await agentRunRepository.loadConversations() else { return }
            let visible = restored.filter {
                self?.deletedAgentConversationIDs.contains($0.id) != true
            }
            window?.assistantLibrary.restore(visible)
        }
    }

    func shellIntegrationPreferenceDidChange(isEnabled: Bool) {
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            for sshSession in window.workspaces.flatMap(\.panes).compactMap(\.sshSession) {
                sshSession.applyShellIntegrationPreference(isEnabled: isEnabled)
            }
            window.refreshSessionContext()
        }
    }

    private func deleteAgentConversation(_ id: UUID) {
        let wasArchived = conversation(id)?.isArchived == true
        deletedAgentConversationIDs.insert(id)
        titledConversationIDs.remove(id)
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            let wasSelected = window.assistantLibrary.selectedConversationID == id
            window.assistantLibrary.delete(id)
            if wasArchived, wasSelected {
                window.isAssistantArchivePresented = true
            }
            if window.sidebar.assistantConversationID == id {
                window.sidebar.assistantConversationID = nil
                if wasArchived {
                    window.sidebar.isAssistantArchivePresented = true
                }
            }
        }
        Task { [agentRunRepository] in
            try? await agentRunRepository.deleteConversation(id)
            // The scratch scope goes with the conversation that owns it. Nothing
            // else ever collects it, so a chat deleted without this would leave its
            // staged files — possibly a copy of a production config — on disk for
            // the life of the install.
            try? await AgentScratchWorkspace(conversationID: id).removeScope()
        }
    }

    private func conversation(_ id: UUID) -> ConversationModel? {
        assistantConversations.conversation(id: id)
    }

    private func togglePin(_ id: UUID, reportingTo window: WindowModel?) {
        guard let conversation = conversation(id), !conversation.isArchived,
            !conversation.isStreaming, !conversation.isCompacting,
            let library = window?.assistantLibrary
        else { return }
        let toPinned = !conversation.isPinned
        let nextID = (toPinned
            ? library.pinnedConversations
            : library.activeConversations).first?.id
        moveConversation(
            id, toPinned: toPinned, before: nextID, reportingTo: window
        )
    }

    private func moveConversation(
        _ id: UUID,
        toPinned: Bool,
        before nextID: UUID?,
        reportingTo window: WindowModel?
    ) {
        guard let library = window?.assistantLibrary,
            let updates = library.orderUpdates(
                moving: id, toPinned: toPinned, before: nextID
            )
        else { return }
        Task { [weak window, agentRunRepository] in
            do {
                try await agentRunRepository.reorderConversations(updates)
                library.applyOrder(updates)
            } catch {
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    private func renameConversation(
        _ id: UUID, to value: String, reportingTo window: WindowModel?
    ) {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation = conversation(id), !title.isEmpty else { return }
        let customTitle = String(title.prefix(80))
        var metadata = conversation.metadata
        metadata.customTitle = customTitle
        Task { [weak conversation, weak window, agentRunRepository] in
            do {
                try await agentRunRepository.setConversationMetadata(
                    metadata, conversationID: id
                )
                conversation?.customTitle = customTitle
            } catch {
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    private func setArchived(
        _ id: UUID, archived: Bool, reportingTo window: WindowModel?
    ) {
        guard let conversation = conversation(id), !conversation.isStreaming,
            !conversation.isCompacting
        else { return }
        var metadata = conversation.metadata
        metadata.archivedAt = archived ? .now : nil
        if archived { metadata.isPinned = false }
        Task { [weak conversation, weak window, agentRunRepository] in
            do {
                try await agentRunRepository.setConversationMetadata(
                    metadata, conversationID: id
                )
                conversation?.archivedAt = metadata.archivedAt
                conversation?.isPinned = metadata.isPinned
            } catch {
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    private func forkConversation(
        _ id: UUID, at messageID: UUID, selectingIn window: WindowModel?,
        inSidebar: Bool
    ) {
        guard let source = conversation(id) else { return }
        let title = assistantConversations.nextForkTitle(for: source)
        guard let fork = source.forked(
            throughAssistantMessage: messageID, title: title
        )
        else { return }
        let stored = StoredAgentConversation(
            id: fork.id, messages: fork.transcript,
            messageRunIDs: fork.messageRunIDs,
            runs: Array(fork.runSummaries.values),
            toolCards: fork.toolCards.map {
                StoredAgentToolCard(
                    invocation: $0.invocation, descriptor: $0.descriptor,
                    state: $0.state.rawValue, result: $0.result, review: $0.review
                )
            }, lastRunState: .completed, title: "", metadata: fork.metadata
        )
        Task { [weak self, weak window, agentRunRepository] in
            do {
                try await Task.detached(priority: .utility) {
                    try AgentScratchWorkspace.copyScope(from: id, to: fork.id)
                }.value
                try await agentRunRepository.createConversation(stored)
                guard let self else { return }
                self.assistantConversations.insert(fork)
                if inSidebar { window?.openAssistantInSidebar(fork.id) }
                else { window?.selectAssistant(fork.id) }
            } catch {
                try? await AgentScratchWorkspace(conversationID: fork.id).removeScope()
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    private func editConversation(
        _ id: UUID, messageID: UUID, text value: String,
        context: SessionContext, includesTerminalSuggestion: Bool,
        reportingTo window: WindowModel?
    ) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = conversation(id),
            let replacement = conversation.editedUserMessage(
                messageID, authoredText: text
            )
        else { return }
        Task { [weak self, weak conversation, weak window, agentRunRepository] in
            do {
                try await agentRunRepository.truncateConversation(
                    id, fromUserMessageID: messageID, replacingWith: replacement
                )
                guard let self, let conversation,
                    let prompt = conversation.editUserMessage(
                        messageID, replacement: replacement
                    )
                else { return }
                self.titledConversationIDs.remove(id)
                self.startAgentRun(
                    conversation, promptID: prompt.id, prompt: prompt.text,
                    authoredPrompt: prompt.authoredText, promptImages: prompt.images,
                    promptContextAttachments: prompt.contextAttachments,
                    context: context,
                    includesTerminalSuggestion: includesTerminalSuggestion
                )
            } catch {
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func requestHostDeletion(_ hostID: Host.ID) -> Bool {
        do {
            try hostRepository.requestHostDeletion(hostID)
            commandHistory.clear(for: hostID)
            sftpHistory.clear(for: hostID)
            connectionHistory.clear(for: hostID)
            hosts.projectHostDeletion(hostID)
            return true
        } catch {
            hosts.reportStorageError(error)
            return false
        }
    }

    func deleteHostGroup(_ groupID: HostGroup.ID, keepHosts: Bool) {
        if !keepHosts {
            let affected = hosts.hosts(inTreeOf: groupID)
            guard affected.allSatisfy({ requestHostDeletion($0.id) }) else { return }
        }
        hosts.deleteGroupProjection(groupID)
    }

    private func closeWorkspaces(for hostID: Host.ID) {
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            window.closeWorkspaces(for: hostID)
        }
    }

    private func temporaryAgentTargets() -> [AgentHostTarget] {
        windows = windows.filter { $0.value.value != nil }
        var seen = Set<UUID>()
        return windows.values.compactMap(\.value).flatMap(\.workspaces).flatMap(\.panes)
            .compactMap(\.sshSession).compactMap(\.agentTemporaryTarget)
            .filter { seen.insert($0.id).inserted }
    }

    private func temporaryAgentConfiguration(
        for hostID: UUID
    ) -> SSHConnectionConfiguration? {
        windows = windows.filter { $0.value.value != nil }
        return windows.values.compactMap(\.value).flatMap(\.workspaces).flatMap(\.panes)
            .compactMap(\.sshSession)
            .first { $0.hostID == hostID && $0.agentTemporaryTarget != nil }?
            .agentConnectionConfiguration
    }

    /// Starts teardown without waiting for network peers. AppKit's termination
    /// path runs on the main thread, so awaiting SSH/SFTP shutdown here can make
    /// ⌘Q appear hung when a peer is slow or unreachable.
    func shutdownForTermination() {
        speechTranscription.cancelAll()
        let liveWindows = windows.values.compactMap(\.value)
        windows.removeAll()
        for window in liveWindows { window.closeAll() }
        sftpTransfers.cancelAll()
        forwarding.stopAll()
        Task { [mcpServer, agentConnections, agentBackgroundCommands] in
            await mcpServer.stop()
            await agentBackgroundCommands.closeAll()
            await agentConnections.closeAll()
        }
        outboxRunner?.stop()
    }

    /// Opens a host in the given window, handing back the workspace it landed in.
    ///
    /// The initial status flip is optimistic; once the terminal appears, its SSH
    /// session reports the authoritative state back to `HostLibraryModel`.
    ///
    /// The return value exists for `open(_:as:in:)`'s plural form, which has to
    /// know which workspace was first. Discardable because nearly every caller opens
    /// one host and has nothing to decide afterwards.
    @discardableResult
    func open(
        _ host: Host,
        as target: HostOpenTarget,
        in window: WindowModel
    ) -> Workspace {
        beginOpening(host, as: target)

        switch target {
        case .sshSession: return window.openSSHSession(host: host)
        case .sftpSession: return window.openSFTPSession(host: host)
        }
    }

    /// Opens an unsaved Welcome destination without putting it into SwiftData.
    /// Its username travels with the SSH session and seeds the credential
    /// prompt when there is no saved Identity to resolve.
    @discardableResult
    func openQuickConnect(_ target: QuickConnectTarget, in window: WindowModel) -> Workspace {
        hosts.setStatus(.connecting, for: target.host.id)
        return window.openSSHSession(host: target.host, usernameHint: target.username)
    }

    /// Turns one Welcome destination into an ordinary saved Host. A typed
    /// username is saved as an Identity only when no existing Identity was
    /// resolved for it; authentication can then be completed by the session's
    /// Continue and Save prompt.
    @discardableResult
    func saveQuickConnect(_ target: QuickConnectTarget) -> Host {
        var host = target.host
        if host.identityID == nil,
            let username = target.username?.trimmingCharacters(in: .whitespaces),
            !username.isEmpty
        {
            let identity = Identity(name: username, username: username)
            hosts.upsert(identity)
            host.identityID = identity.id
        }
        hosts.upsert(host)
        return host
    }

    /// Mark as recently used, and flip the status dot.
    ///
    /// Its own method because three code paths now open hosts — one, a batch of
    /// workspaces, and a batch into one Workspace — and *where it lands* is the only
    /// thing that should differ between them. Inlining this was fine while there
    /// were two.
    private func beginOpening(_ host: Host, as target: HostOpenTarget) {
        if hosts.host(host.id) != nil {
            connectionHistory.record(
                kind: target == .sshSession ? .ssh : .sftp,
                for: host.id
            )
        }
        switch target {
        case .sshSession:
            hosts.setStatus(.connecting, for: host.id)
        case .sftpSession:
            break
        }
    }

    /// Clears every user-facing history owned by the selected saved Hosts.
    /// Host records and credentials remain intact.
    func clearAllHistory(for hostIDs: [Host.ID]) {
        for hostID in Set(hostIDs) {
            connectionHistory.clear(for: hostID)
            commandHistory.clear(for: hostID)
            sftpHistory.clear(for: hostID)
        }
    }

    /// Clears the global connection timeline and the Recents projection it
    /// supersedes in the History sidebar.
    func clearConnectionHistory() {
        connectionHistory.clearAll()
    }

    /// Saved Hosts ordered by their latest connection event, with each Host
    /// appearing only once.
    func recentHosts(limit: Int = 5) -> [Host] {
        var seen = Set<Host.ID>()
        return connectionHistory.entries().compactMap { entry in
            guard seen.insert(entry.hostID).inserted else { return nil }
            return hosts.host(entry.hostID)
        }.prefix(limit).map { $0 }
    }

    func lastConnectedAt(for hostID: Host.ID) -> Date? {
        connectionHistory.mostRecentDate(for: hostID)
    }

    /// Batch Startup, in either of its two shapes.
    ///
    /// The workspaces path is a loop over the singular `open` rather than its own code
    /// path; the Workspace path cannot be, since the whole point is that it makes
    /// one workspace. What both share is `beginOpening`, so the bookkeeping cannot
    /// drift between them.
    ///
    /// In the workspaces case each `open` selects the workspace it made, which would leave
    /// the *last* host in front — the one furthest from where the eye started.
    /// Landing on the first instead matches the order the list was read and
    /// ticked in, and the rest are a ⌃⇥ away.
    func open(
        _ hosts: [Host],
        as target: HostOpenTarget,
        layout: BatchLayout = .separateWorkspaces,
        in window: WindowModel
    ) {
        switch layout {
        case .separateWorkspaces:
            let opened = hosts.map { open($0, as: target, in: window) }
            if let first = opened.first { window.select(first.id) }
        case .oneWorkspace:
            guard proAccess.require(.workspaceComposition) else { return }
            for host in hosts { beginOpening(host, as: target) }
            window.openWorkspace(hosts, as: target)
        }
    }

    /// Turns Snippet execution into ordinary visible sessions rather than a
    /// hidden job. `overrideHostIDs` powers Execute on Hosts; `fallbackHostIDs`
    /// is used only by snippets whose saved target list is empty.
    func execute(
        _ snippets: [Snippet], overrideHostIDs: [Host.ID]? = nil,
        fallbackHostIDs: [Host.ID]? = nil, in window: WindowModel
    ) {
        var opened: [Workspace] = []
        for snippet in snippets {
            let ids =
                overrideHostIDs
                ?? (snippet.targetHostIDs.isEmpty
                    ? (fallbackHostIDs ?? []) : snippet.targetHostIDs)
            let wanted = Set(ids)
            let targets = hosts.searchHosts("").filter { wanted.contains($0.id) }
            guard !targets.isEmpty else { continue }
            if targets.count > 1, !proAccess.require(.workspaceComposition) { return }
            for host in targets { beginOpening(host, as: .sshSession) }
            if let workspace = window.openSnippetWorkspace(
                hosts: targets, command: snippet.body
            ) {
                opened.append(workspace)
            }
        }
        if let first = opened.first { window.select(first.id) }
    }

    /// ⌘T, the window toolbar's `+`, the workspace bar's `+`, and Welcome. Raises the
    /// host chooser.
    ///
    /// Termind has no local shell, so "new session" has to name a machine. A sheet
    /// rather than the Hosts page: the page is a manager — it edits, groups, and
    /// deletes — and sending every ⌘T there meant navigating away from whatever
    /// was on screen just to ask one question.
    ///
    /// The sheet starts with nothing selected, deliberately. A command that
    /// connects to a selection made earlier, on another screen, is how a
    /// keystroke meant for staging lands on production. ⌘T never connects on its
    /// own; it puts the question up, and Return answers it.
    func connect(in window: WindowModel) {
        window.hostChooser = .connect
    }

    /// The Batch Startup row at the foot of the sidebar's Sessions section. The
    /// same sheet again, in its multi-select
    /// mode — see `HostChooserPurpose`.
    ///
    /// The sidebar and Welcome page raise this chooser. It is not in the File
    /// menu or the workspace bar's `+`: bringing up a dozen machines is a deliberate
    /// act, kept on surfaces that name Batch Startup directly.
    func batchStartup(in window: WindowModel) {
        window.hostChooser = .batchStartup
    }

    /// Parses `user@host:port` typed into the quick-connect field. Returns nil
    /// when the input is not a plausible destination, so the field can stay
    /// quiet rather than flashing an error on every keystroke.
    ///
    /// A typed login name is resolved when exactly one saved Identity uses it.
    /// It also remains on the transient target so `a@b` always connects as `a`,
    /// even when no Identity exists yet. Nothing is persisted until Save or
    /// Continue and Save is chosen.
    func parseQuickConnect(_ input: String) -> QuickConnectTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        var username: String?
        var remainder = trimmed[...]
        if let at = trimmed.lastIndex(of: "@") {
            let typed = String(trimmed[trimmed.startIndex..<at])
            guard !typed.isEmpty else { return nil }
            username = typed
            remainder = trimmed[trimmed.index(after: at)...]
        }

        guard let (host, port) = Self.splitPort(String(remainder)) else { return nil }
        guard !host.isEmpty, host.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }

        // Ambiguity is left unresolved rather than guessed at: two identities
        // named `root` differ in which key they present, and picking one for the
        // user would be picking a credential for them.
        let matches = username.map { name in hosts.identities.filter { $0.username == name } }
        let identityID = matches?.count == 1 ? matches?.first?.id : nil

        return QuickConnectTarget(
            host: Host(name: host, host: host, port: port, identityID: identityID),
            username: username
        )
    }

    /// Splits `host`, `host:port`, or `[v6]:port` into its two halves.
    ///
    /// The bracket case is the reason this is not one `lastIndex(of: ":")`: a bare
    /// IPv6 literal is *all* colons, and naive splitting turns `2001:db8::1` into
    /// the host `2001:db8:` on port 1 — a plausible-looking address that is not
    /// the one anybody typed. So brackets mean "port follows", more than one colon
    /// without them means "this is IPv6, no port".
    private static func splitPort(_ input: String) -> (host: String, port: Int)? {
        if input.hasPrefix("[") {
            guard let close = input.firstIndex(of: "]") else { return nil }
            let host = String(input[input.index(after: input.startIndex)..<close])
            let rest = input[input.index(after: close)...]
            if rest.isEmpty { return (host, 22) }
            guard rest.hasPrefix(":"), let port = parsePort(rest.dropFirst()) else { return nil }
            return (host, port)
        }

        let colons = input.filter { $0 == ":" }.count
        switch colons {
        case 0:
            return (input, 22)
        case 1:
            let parts = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let port = parsePort(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default:
            return (input, 22)
        }
    }

    private static func parsePort(_ text: Substring) -> Int? {
        guard let value = Int(text), (1...65_535).contains(value) else { return nil }
        return value
    }
}
