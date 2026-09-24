import AgentKit
import AgentKitScrubber
import AppKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

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
    case preferredTerminal
    case sshSession
    case telnetSession
    case sftpChannel
}

/// App-wide state shared by every window: the saved hosts, and the one code path
/// for opening them.
///
/// Everything the user can have in a *different* state in a second window —
/// workspaces, sidebar selection, search text, Sidebar visibility — lives on
/// `WindowModel` instead.
@Observable
final class AppModel {
    private var terminationTask: Task<Void, Never>?
    private var isTerminating = false
    private final class WeakWindow {
        weak var value: WindowModel?
        init(_ value: WindowModel) { self.value = value }
    }

    private let hosts: HostLibraryModel
    let proAccess: ProAccessController
    var hostLibrary: HostLibraryModel { hosts }
    let knownHosts: KnownHostsLibraryModel
    let credentials: CredentialLibraryModel
    let snippets: SnippetLibraryModel
    let forwardings: ForwardingLibraryModel
    let transfers: TransferLibraryModel
    let commandHistory: CommandHistoryModel
    let sftpHistory: SFTPHistoryModel
    let connectionHistory: ConnectionHistoryModel
    let devices: DeviceDirectoryModel
    private let externalToolCalls: ToolAuditModel
    var toolAudit: ToolAuditModel { externalToolCalls }
    let externalAuthentication: ExternalAuthCoordinator
    let mcpServer: MCPServerController
    let commands = AppCommandRegistry()
    let onboarding: OnboardingController
    let appReview: AppReviewController
    let serverMetrics: ServerMetricsModel
    let windowSizeStore: MainWindowSizeStore
    let logging: any ApplicationLogManaging
    @ObservationIgnored lazy var mainWindows = MainWindowCoordinator(app: self, sizes: windowSizeStore)
    let connections: RemoteConnectionCoordinator
    let serialPorts: any SerialPortServing
    let hostRepository: any HostRepository
    let settingsSync: SettingsSyncCoordinator?
    let metricsSync: MetricsSyncCoordinator?
    let vaultSync: VaultSyncCoordinator?
    let historySync: HistorySyncCoordinator?
    let forwarding: PortForwardingController
    let sftpEdits: SFTPEditService
    let sftpTransfers: SFTPTransferCoordinator
    /// Providers, models, role assignments, MCP servers.
    ///
    /// Its own store rather than more fields on `HostLibraryModel`: that one is about
    /// machines you connect to, this one about endpoints you spend a key at.
    /// See `AIConfigurationModel`.
    private let ai: AIConfigurationModel
    var aiConfiguration: AIConfigurationModel { ai }
    /// The procedures the user installed for the agent to follow. Its own store
    /// rather than more fields on `ai`: that one is about endpoints you spend a
    /// key at, this is a library of documents. See `SkillLibraryModel`.
    let terminalSettings: TerminalSettingsModel
    let sshSettings: SSHSettingsModel
    let sftpSettings: SFTPSettingsModel
    let workspaceSettings: WorkspaceSettingsModel
    let skills: SkillLibraryModel
    let memory: MemoryModel
    let commandGenerator: CommandGeneratorController
    /// Names conversations for the chat list. Held as the protocol, not the
    /// concrete controller, so a test can watch the trigger without a provider.
    var conversationTitles: any ConversationTitling
    /// One app-wide microphone owner. Keeping this above individual composers
    /// prevents two windows from installing competing audio taps.
    let speechTranscription: SpeechTranscriptionCoordinator
    /// The one set of conversations every window navigates. See
    /// `AssistantConversationStore`.
    private let assistantConversations: AssistantConversationStore
    private let agentRunRepository: any AgentRunPersisting
    private let agentHosts: AgentHostResolver
    private let agentConnections: AgentConnectionPool
    private let agentAuthentication: AgentSSHAuthenticationRegistry
    /// Commands that outlived the turn that started them. App-wide rather than
    /// per-run, because a handle taken in one turn is answered in a later one
    /// and a run ending is not a reason to stop a deploy.
    private let agentBackgroundCommands: AgentBackgroundCommands
    private let outboxRunner: OutboxRunner?
    private let settingsDefaults: UserDefaults
    private let shutdownDependencies: AppShutdownDependencies?
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var deletedAgentConversationIDs = Set<UUID>()
    /// Conversations already handed to the summarizer. Titling is once per
    /// conversation, and every run re-arms the hook that would do it.

    func makeSSHImportModel() -> SSHImportModel {
        SSHImportModel(
            library: hosts, reader: SSHImportReader(),
            storage: newVaultPasswordStorage)
    }

    var newVaultKeyStorage: KeyStorage {
        NewVaultCredentialStorage.keyStorage(
            defaults: settingsDefaults,
            canUseVaultSync: proAccess.canUse(.vaultSync))
    }

    var newVaultPasswordStorage: PasswordStorage {
        NewVaultCredentialStorage.passwordStorage(
            defaults: settingsDefaults,
            canUseVaultSync: proAccess.canUse(.vaultSync))
    }

    init(
        hosts: HostLibraryModel, ai: AIConfigurationModel = AIConfigurationModel(),
        skills: SkillLibraryModel = SkillLibraryModel(),
        memory: MemoryModel = MemoryModel(),
        terminalSettings: TerminalSettingsModel = TerminalSettingsModel(),
        sshSettings: SSHSettingsModel = SSHSettingsModel(),
        sftpSettings: SFTPSettingsModel = SFTPSettingsModel(),
        workspaceSettings: WorkspaceSettingsModel = WorkspaceSettingsModel(),
        commandHistory: CommandHistoryModel = CommandHistoryModel(),
        sftpHistory: SFTPHistoryModel = SFTPHistoryModel(),
        connectionHistory: ConnectionHistoryModel = ConnectionHistoryModel(),
        devices: DeviceDirectoryModel? = nil,
        externalToolCalls: ToolAuditModel = ToolAuditModel(),
        dependencies: AppDependencies? = nil,
        speechTranscription: SpeechTranscriptionCoordinator? = nil,
        proAccess: ProAccessController = .unrestrictedForTesting(),
        onboarding: OnboardingController = OnboardingController(),
        appReview: AppReviewController = AppReviewController(),
        serverMetrics suppliedMetrics: ServerMetricsModel? = nil,
        windowSizeStore: MainWindowSizeStore = MainWindowSizeStore()
    ) {
        self.windowSizeStore = windowSizeStore
        let dependencies = dependencies ?? .inMemory(hosts: hosts.hosts, groups: hosts.groups)
        settingsDefaults = dependencies.settingsDefaults
        assistantConversations = dependencies.assistantConversations ?? AssistantConversationStore()
        shutdownDependencies = dependencies.shutdown
        logging = dependencies.logging
        let externalAuthentication = ExternalAuthCoordinator(
            logger: logging.makeLogger(label: "termind.external-mcp"))
        self.externalAuthentication = externalAuthentication
        let connectionCoordinator = dependencies.connectionCoordinator.withKeyboardInteractive(
            externalAuthentication.keyboardInteractive)
        connectionCoordinator.updateSSHPreferences(sshSettings.preferences)
        self.serverMetrics =
            suppliedMetrics
            ?? ServerMetricsModel(
                hosts: hosts, preferences: dependencies.metricsPreferences ?? MetricsPreferences(),
                makeSampler: { connectionCoordinator.makeMetricsSampler() },
                cardLimit: { proAccess.canUse(.unlimitedMetrics) ? nil : ServerMetricsModel.freeCardLimit },
                limitReached: { proAccess.require(.unlimitedMetrics) }
            )
        self.hosts = hosts
        self.proAccess = proAccess
        self.onboarding = onboarding
        self.appReview = appReview
        knownHosts = KnownHostsLibraryModel(library: hosts)
        credentials = CredentialLibraryModel(library: hosts)
        snippets = SnippetLibraryModel(library: hosts)
        forwardings = ForwardingLibraryModel(library: hosts)
        transfers = TransferLibraryModel(library: hosts)
        self.commandHistory = commandHistory
        self.sftpHistory = sftpHistory
        self.connectionHistory = connectionHistory
        self.devices = devices ?? DeviceDirectoryModel(currentDeviceID: connectionHistory.sourceDeviceID)
        self.externalToolCalls = externalToolCalls
        connections = connectionCoordinator
        serialPorts = dependencies.serialPortService
        agentRunRepository = MemoryIndexedAgentRepository(
            base: dependencies.agentRunRepository ?? InMemoryAgentRunRepository(), memory: memory)
        let sftpConcurrencyScheduler = SFTPConcurrencyScheduler(preferences: sftpSettings.preferences)
        let agentHostServices = AgentHostServices.live(
            store: hosts,
            coordinator: connectionCoordinator,
            sftpConcurrencyScheduler: sftpConcurrencyScheduler)
        agentHosts = agentHostServices.resolver
        agentAuthentication = agentHostServices.authentication
        agentConnections = agentHostServices.connections
        agentBackgroundCommands = agentHostServices.background
        hostRepository = dependencies.hostRepository
        vaultSync = dependencies.vaultSync
        historySync = dependencies.historySync
        settingsSync = dependencies.settingsSync
        metricsSync = dependencies.metricsSync
        forwarding = PortForwardingController(
            hosts: hosts, poolPolicy: .hostConfigured,
            logger: dependencies.logging.makeLogger(label: "termind.port-forwarding"))
        sftpTransfers = SFTPTransferCoordinator(
            store: hosts,
            clientFactory: { connectionCoordinator.makeSFTPClient() },
            globalLimit: sftpSettings.preferences.globalLimit,
            perHostLimit: sftpSettings.preferences.perHostLimit,
            strategy: sftpSettings.preferences.strategy,
            concurrencyScheduler: sftpConcurrencyScheduler
        )
        sftpEdits = SFTPEditService(transfers: sftpTransfers, host: { [weak hosts] in hosts?.host($0) })
        self.ai = ai
        self.skills = skills
        self.memory = memory
        self.terminalSettings = terminalSettings
        self.sshSettings = sshSettings
        self.sftpSettings = sftpSettings
        self.workspaceSettings = workspaceSettings
        commandGenerator = CommandGeneratorController(ai: ai)
        conversationTitles = ConversationTitleController(ai: ai)
        self.speechTranscription =
            speechTranscription
            ?? SpeechTranscriptionCoordinator(
                service: AppleSpeechTranscriptionService(audioInput: MacOSSpeechAudioInput())
            )
        outboxRunner = dependencies.outboxRunner
        mcpServer = MCPServerController(
            secrets: dependencies.mcpServerSecrets, hosts: agentHosts, metrics: serverMetrics,
            connections: agentConnections,
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
        hosts.willDeleteHost = {
            [weak forwarding, weak serverMetrics, weak mcpServer, agentConnections, weak sftpEdits] hostID, ruleIDs in
            sftpEdits?.invalidate(hostID: hostID)
            mcpServer?.tools.revokeHost(hostID)
            serverMetrics?.remove(hostID)
            forwarding?.hostConfigurationChanged(hostID)
            forwarding?.stop(ruleIDs)
            // Not a `HostDeletionOutbox` step like the others: a live socket
            // cannot outlive the process, so there is nothing to replay after a
            // crash and nothing to make durable.
            Task { await agentConnections.disconnect(hostID: hostID) }
        }
        hosts.willDeletePortForwardings = { [weak forwarding] ruleIDs in
            forwarding?.stop(ruleIDs)
        }
        hosts.didChangeHostConnection = { [weak forwarding, weak self] hostID in
            forwarding?.hostConfigurationChanged(hostID)
            guard let self else { return }
            let message =
                self.hosts.host(hostID)?.sshEnabled == true
                ? String(localized: AppStrings.Connections.theHostConfigurationChangedReconnectToApplyIt)
                : String(localized: AppStrings.Connections.sshIsDisabledForThisHost)
            self.disconnectWorkspaces(for: hostID, protocol: .ssh, message: message)
        }
        hosts.didChangeTelnetConnection = { [weak self] hostID in
            guard let self else { return }
            let message =
                self.hosts.host(hostID)?.telnetEnabled == true
                ? String(localized: AppStrings.Connections.theHostConfigurationChangedReconnectToApplyIt)
                : String(localized: AppStrings.Connections.telnetIsDisabledForThisHost)
            self.disconnectWorkspaces(for: hostID, protocol: .telnet, message: message)
        }
        hosts.didPersistCore = { [weak repository = dependencies.hostRepository] in
            try? repository?.refresh()
        }
        hosts.didRecordVaultChanges = { [weak vaultSync = dependencies.vaultSync] mutations in
            vaultSync?.noteLocalChanges(mutations)
        }
        if let repository = dependencies.hostRepository as? SwiftDataHostRepository {
            repository.didRecordHistoryChanges = { [weak historySync = dependencies.historySync] in
                historySync?.noteLocalChanges($0)
            }
            repository.didRecordVaultChanges = { [weak vaultSync = dependencies.vaultSync] mutations in
                vaultSync?.noteLocalChanges(mutations)
            }
        }
        if let outboxRunner {
            outboxRunner.registerHostDeletionHandlers(
                repository: hostRepository,
                closeWorkspaces: { [weak self] deletion in
                    self?.closeWorkspaces(for: deletion.hostID)
                    self?.connectionHistory.clear(for: deletion.hostID)
                },
                cancelTransfers: { [weak self] deletion in
                    self?.sftpEdits.invalidate(hostID: deletion.hostID)
                    self?.sftpTransfers.cancelAll(for: deletion.hostID)
                    self?.externalAuthentication.cancel(hostID: deletion.hostID)
                    self?.mcpServer.tools.revokeHost(deletion.hostID)
                    if let self { Task { await self.mcpServer.tools.cancelHostTransfers(deletion.hostID) } }
                },
                stopForwardings: { [weak self] deletion in
                    self?.forwarding.hostConfigurationChanged(deletion.hostID)
                    self?.forwarding.remove(deletion.forwardingRuleIDs)
                }
            )
            outboxRunner.start()
        }
        historySync?.didApplyRemote = { [weak self] keys in
            if keys.contains(where: { $0.kind == .connectionHistory }) { self?.connectionHistory.reload() }
            if keys.contains(where: { $0.kind == .device }) { self?.devices.reload() }
        }
        vaultSync?.didApplyRemote = { [weak self] snapshot, keys in
            self?.applyRemoteVaultSnapshot(snapshot, changedKeys: keys)
        }
        sftpSettings.didChange = { [weak sftpTransfers] preferences in
            sftpTransfers?.updatePreferences(preferences)
        }
        sshSettings.didChange = { preferences in
            connectionCoordinator.updateSSHPreferences(preferences)
        }
        settingsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.ai.applyRemoteSnapshot(snapshot.configuration, webSearch: snapshot.webSearch)
            self?.skills.applyRemoteSnapshot(snapshot.skills)
            self?.terminalSettings.applyRemoteSnapshot(snapshot.terminal)
            self?.sshSettings.applyRemoteSnapshot(snapshot.ssh)
            self?.sftpSettings.applyRemoteSnapshot(snapshot.sftp)
            self?.workspaceSettings.applyRemoteSnapshot(snapshot.workspace)
        }
        metricsSync?.didApplyRemote = { [weak serverMetrics] snapshot, _ in
            serverMetrics?.applyRemoteSnapshot(snapshot)
        }
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            historySync?.start()
            metricsSync?.start()
            settingsSync?.start()
        }
    }

    func reconcileProAccess() {
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            historySync?.start()
            metricsSync?.start()
            settingsSync?.start()
            mcpServer.resumeForProAccess()
        } else {
            vaultSync?.pause()
            historySync?.pause()
            metricsSync?.pause()
            settingsSync?.pause()
        }
        if !proAccess.canUse(.mcpServer), mcpServer.isEnabled {
            mcpServer.suspendForProAccess()
        }
    }

    private func applyRemoteVaultSnapshot(
        _ snapshot: VaultSnapshot, changedKeys: Set<VaultRecordKey>
    ) {
        let plan = VaultRemoteChangePlan.make(
            currentHosts: hosts.hosts,
            snapshot: snapshot,
            changedKeys: changedKeys
        )
        for change in plan.hosts {
            if change.routeChanged {
                hosts.willDeleteHost?(change.id, hosts.portForwardings(for: change.id).map(\.id))
            }
            if change.isRemoved {
                closeWorkspaces(for: change.id)
                sftpEdits.invalidate(hostID: change.id)
                sftpTransfers.cancelAll(for: change.id)
                externalAuthentication.cancel(hostID: change.id)
                mcpServer.tools.revokeHost(change.id)
                commandHistory.clear(for: change.id)
                sftpHistory.clear(for: change.id)
                connectionHistory.clear(for: change.id)
            }
        }
        if !plan.forwardingRuleIDs.isEmpty { forwarding.stop(plan.forwardingRuleIDs) }
        hosts.replacePersistedSnapshot(snapshot)
        forwarding.reconcileConfiguration()
    }

    @ObservationIgnored private lazy var assistantOperations = AssistantConversationOperations(
        repository: agentRunRepository)

    @ObservationIgnored private lazy var assistantExecution = AssistantExecutionController(
        ai: ai, skills: skills, repository: agentRunRepository, memory: memory,
        authorize: { [weak self] in
            guard let self, !self.isTerminating else { return false }
            return self.proAccess.require(.assistant)
        },
        makeRegistry: { [weak self] conversation, model, provider, skills, channel in
            guard let self else { return AgentToolRegistry([AnyAgentTool]()) }
            return AssistantToolRegistry.make(
                conversation: conversation, model: model, provider: provider,
                skills: skills, channel: channel, ai: ai, hosts: agentHosts, metrics: serverMetrics,
                connections: agentConnections, authentication: agentAuthentication,
                background: agentBackgroundCommands)
        },
        title: { [weak self] context in
            guard let self else { throw CancellationError() }
            return try await conversationTitles.summarize(context)
        },
        logger: logging.makeLogger(label: "termind.agent"))

    func sendAgentDraft(
        _ conversation: ConversationModel, context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false
    ) {
        assistantExecution.sendAgentDraft(
            conversation, context: context, terminalSuggestionsAvailable: terminalSuggestionsAvailable)
    }

    @discardableResult
    func sendNewAgentConversation(
        _ conversation: ConversationModel, in library: AssistantLibraryModel,
        context: SessionContext = .none, terminalSuggestionsAvailable: Bool = false
    ) -> ConversationModel? {
        assistantExecution.sendNewConversation(
            conversation, in: library, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
    }

    @discardableResult
    func sendNewAgentDraft(
        in library: AssistantLibraryModel, context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false
    ) -> ConversationModel? {
        assistantExecution.sendDraftConversation(
            in: library, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
    }

    @discardableResult
    func sendAgentText(
        _ text: String, in conversation: ConversationModel,
        context: SessionContext = .none, terminalSuggestionsAvailable: Bool = false
    ) -> Bool {
        assistantExecution.sendAgentText(
            text, in: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
    }

    @discardableResult
    func sendPlanImplementation(
        _ card: AgentPlanCard, in conversation: ConversationModel,
        context: SessionContext = .none, terminalSuggestionsAvailable: Bool = false
    ) -> Bool {
        assistantExecution.sendPlanImplementation(
            card, in: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable)
    }

    func startAgentRun(
        _ conversation: ConversationModel, promptID: UUID? = nil, prompt: String? = nil,
        authoredPrompt: String? = nil, promptImages: [AgentImageAttachment]? = nil,
        promptContextAttachments: [AgentContextAttachment]? = nil,
        context: SessionContext? = nil, terminalSuggestionsAvailable: Bool = false
    ) {
        assistantExecution.startAgentRun(
            conversation, promptID: promptID, prompt: prompt,
            authoredPrompt: authoredPrompt, promptImages: promptImages,
            promptContextAttachments: promptContextAttachments,
            context: context, terminalSuggestionsAvailable: terminalSuggestionsAvailable)
    }

    @discardableResult
    func compact(_ conversation: ConversationModel, instructions: String = "", isManual: Bool = true) async -> Bool {
        await assistantExecution.compact(conversation, instructions: instructions, isManual: isManual)
    }

    func persistAndApplyCompaction(_ record: AgentCompactionRecord, to conversation: ConversationModel, cut: Int)
        async throws
    {
        try await assistantExecution.persistAndApplyCompaction(record, to: conversation, cut: cut)
    }

    static func titleContext(for conversation: ConversationModel) -> ConversationTitleContext? {
        AssistantExecutionController.titleContext(for: conversation)
    }

    func unregisterWindow(_ window: WindowModel) {
        windows[ObjectIdentifier(window)] = nil
        onboarding.windowClosed(window)
    }

    func registerWindow(_ window: WindowModel) {
        guard !window.isClosed, windows[ObjectIdentifier(window)]?.value !== window else { return }
        configureConnectionHistory(in: window)
        window.connectionCoordinator = connections
        window.hostStore = hosts
        window.metricsModel = serverMetrics
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
            edit: { [weak self, weak window] id, messageID, text, context, terminalSuggestionsAvailable in
                self?.editConversation(
                    id, messageID: messageID, text: text, context: context,
                    terminalSuggestionsAvailable: terminalSuggestionsAvailable, reportingTo: window
                )
            }
        )
        Task { [agentRunRepository, weak window, weak self] in
            guard let restored = try? await agentRunRepository.loadConversations(),
                window?.isClosed == false
            else { return }
            let visible = restored.filter {
                self?.deletedAgentConversationIDs.contains($0.id) != true
            }
            window?.assistantLibrary.restore(visible)
        }
    }

    private func deleteAgentConversation(_ id: UUID) {
        guard let conversation = conversation(id) else { return }
        Task {
            do {
                let result = try await assistantOperations.delete(conversation)
                guard result.deleted else { return }
                let wasArchived = conversation.isArchived
                deletedAgentConversationIDs.insert(id)
                windows = windows.filter { $0.value.value != nil }
                for window in windows.values.compactMap(\.value) {
                    window.transcriptCache.removeConversation(id)
                    let wasSelected = window.assistantLibrary.selectedConversationID == id
                    window.assistantLibrary.delete(id)
                    if wasArchived, wasSelected {
                        window.presentAssistantArchive()
                    }
                }
                if let error = result.cleanupError {
                    for window in windows.values.compactMap(\.value) { window.assistantOperationError = error }
                }
            } catch {
                for window in windows.values.compactMap(\.value) {
                    window.assistantOperationError = error.localizedDescription
                }
            }
        }
    }

    private func conversation(_ id: UUID) -> ConversationModel? {
        assistantConversations.conversation(id: id)
    }

    private func togglePin(_ id: UUID, reportingTo window: WindowModel?) {
        guard let conversation = conversation(id), !conversation.isArchived,
            let library = window?.assistantLibrary
        else { return }
        let toPinned = !conversation.isPinned
        let nextID =
            (toPinned
            ? library.pinnedConversations
            : library.activeConversations).first?.id
        moveConversation(
            id, toPinned: toPinned, before: nextID, reportingTo: window
        )
    }

    private func moveConversation(_ id: UUID, toPinned: Bool, before nextID: UUID?, reportingTo window: WindowModel?) {
        guard let conversation = conversation(id), let library = window?.assistantLibrary else { return }
        Task { [weak window] in
            do {
                try await assistantOperations.move(conversation, pinned: toPinned, before: nextID, library: library)
            } catch { window?.assistantOperationError = error.localizedDescription }
        }
    }

    private func renameConversation(_ id: UUID, to value: String, reportingTo window: WindowModel?) {
        guard let conversation = conversation(id) else { return }
        Task { [weak window] in
            do { try await assistantOperations.rename(conversation, title: value) } catch {
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    private func setArchived(_ id: UUID, archived: Bool, reportingTo window: WindowModel?) {
        guard let conversation = conversation(id) else { return }
        Task { [weak window] in
            do {
                try await assistantOperations.setArchived(archived, conversation: conversation)
                if archived && conversation.isArchived { moveOpenConversationSurfacesToNewChat(id) }
            } catch { window?.assistantOperationError = error.localizedDescription }
        }
    }

    private func moveOpenConversationSurfacesToNewChat(_ id: UUID) {
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            window.assistantConversationWasArchived(id)
        }
    }

    private func forkConversation(_ id: UUID, at messageID: UUID, selectingIn window: WindowModel?, inSidebar: Bool) {
        guard let source = conversation(id) else { return }
        let title = assistantConversations.nextForkTitle(for: source)
        Task { [weak window] in
            do {
                guard let fork = try await assistantOperations.fork(source, at: messageID, title: title) else { return }
                fork.attachmentLoader = .live
                assistantConversations.insert(fork)
                if inSidebar { window?.openAssistantInSidebar(fork.id) } else { window?.selectAssistant(fork.id) }
            } catch { window?.assistantOperationError = error.localizedDescription }
        }
    }

    private func editConversation(
        _ id: UUID, messageID: UUID, text value: String,
        context: SessionContext, terminalSuggestionsAvailable: Bool, reportingTo window: WindowModel?
    ) {
        guard let conversation = conversation(id) else { return }
        guard
            let prepared = assistantExecution.prepareAgentEdit(
                conversation, messageID: messageID, text: value, context: context,
                terminalSuggestionsAvailable: terminalSuggestionsAvailable)
        else { return }
        Task { [weak window] in
            do {
                _ = try await assistantExecution.performAgentEdit(
                    prepared, in: conversation, operations: assistantOperations)
            } catch { window?.assistantOperationError = error.localizedDescription }
        }
    }

    @discardableResult
    func requestHostDeletion(_ hostID: Host.ID) -> Bool {
        do {
            try hostRepository.requestHostDeletion(hostID)
            forwarding.hostConfigurationChanged(hostID)
            forwarding.remove(hosts.portForwardings(for: hostID).map(\.id))
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

    private func disconnectWorkspaces(
        for hostID: Host.ID, protocol connectionProtocol: HostTerminalProtocol, message: String
    ) {
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            window.disconnectSessions(for: hostID, protocol: connectionProtocol, message: message)
        }
    }

    private func temporaryAgentTargets() -> [AgentHostTarget] {
        windows = windows.filter { $0.value.value != nil }
        var seen = Set<UUID>()
        return windows.values.compactMap(\.value).flatMap(\.workspaces).flatMap(\.panes)
            .compactMap { pane in
                pane.sshSession?.agentTemporaryTarget ?? pane.telnetSession?.agentTemporaryTarget
            }
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

    /// The delegate gives this asynchronous cleanup a bounded termination window.
    @discardableResult
    func shutdownForTermination() -> Task<Void, Never> {
        isTerminating = true
        if let terminationTask { return terminationTask }
        let conversations = assistantConversations.conversations
        let preparationCancellation = assistantExecution.cancelPendingRuns()
        for conversation in conversations { conversation.stop() }
        let conversationDrains = conversations.map { conversation in
            Task { @MainActor in await conversation.stopAndWait() }
        }
        let task = Task {
            [shutdownDependencies, mcpServer, sftpTransfers, agentBackgroundCommands, agentConnections] in
            async let stopMCP: Void = {
                if let stop = shutdownDependencies?.stopMCP {
                    await stop()
                } else {
                    await mcpServer.stop()
                }
            }()
            async let stopSFTP: Void = {
                if let stop = shutdownDependencies?.stopSFTP {
                    await stop()
                } else {
                    await sftpTransfers.waitForCancellation()
                }
            }()
            await preparationCancellation.value
            for drain in conversationDrains { await drain.value }
            _ = await (stopMCP, stopSFTP)
            if let close = shutdownDependencies?.closeAgentBackgroundCommands {
                await close()
            } else {
                await agentBackgroundCommands.closeAll()
            }
            if let close = shutdownDependencies?.closeAgentConnections {
                await close()
            } else {
                await agentConnections.closeAll()
            }
        }
        terminationTask = task
        memory.suspend()
        sftpEdits.setMonitoring(false)
        serverMetrics.shutdown()
        speechTranscription.cancelAll()
        let liveWindows = windows.values.compactMap(\.value)
        windows.removeAll()
        for window in liveWindows { window.closeAll() }
        sftpTransfers.cancelAll()
        externalAuthentication.cancelAll()
        forwarding.stopAll()
        outboxRunner?.stop()
        return task
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
        configureConnectionHistory(in: window)
        beginOpening(host, as: target)

        switch target {
        case .preferredTerminal:
            switch host.preferredTerminalProtocol {
            case .ssh: return window.openSSHSession(host: host)
            case .telnet: return window.openTelnetSession(host: host)
            case nil: return window.openTelnetSession(host: host)
            }
        case .sshSession: return window.openSSHSession(host: host)
        case .telnetSession: return window.openTelnetSession(host: host)
        case .sftpChannel: return window.openSFTPChannel(host: host)
        }
    }

    @discardableResult
    func openQuickConnect(_ target: QuickConnectTarget, in window: WindowModel) -> Workspace {
        if target.isSaved {
            return open(
                target.host,
                as: target.connectionProtocol == .ssh ? .sshSession : .telnetSession,
                in: window)
        }
        hosts.setStatus(.connecting, for: target.host.id)
        if target.connectionProtocol == .telnet {
            return window.openTelnetSession(host: target.host)
        }
        return window.openSSHSession(
            host: target.host, usernameHint: target.username, connectionRoute: target.route
        )
    }

    @discardableResult
    func saveQuickConnect(_ target: QuickConnectTarget) throws -> Host {
        if target.connectionProtocol == .telnet {
            var host = target.host
            host.sshEnabled = false
            host.telnetEnabled = true
            guard hosts.saveHost(host) else {
                throw TermindSSHError.library(
                    hosts.storageError ?? String(localized: AppStrings.Vault.theHostCouldNotBeSaved))
            }
            return hosts.host(host.id) ?? host
        }
        let route = try hosts.saveConnectionRoute(target.route)
        guard let host = route.hosts.last else { throw SSHConnectionRoute.invalidRouteError }
        return host
    }

    func resolveQuickConnect(_ input: QuickConnectInput, locale: Locale = .current) throws -> QuickConnectTarget {
        try QuickConnectResolver.resolve(input, in: hosts, locale: locale)
    }

    func openExternalConnection(_ url: URL, in window: WindowModel) {
        do {
            let request = try RemoteConnectionURLParser.parse(url)
            if request.kind == .telnet, request.advisoryPassword != nil {
                window.pendingExternalConnection = request
            } else {
                openExternalConnection(request, in: window)
            }
        } catch {
            window.externalConnectionError = error.localizedDescription
        }
    }

    func confirmExternalConnection(in window: WindowModel) {
        guard let request = window.pendingExternalConnection else { return }
        window.pendingExternalConnection = nil
        openExternalConnection(request, in: window)
    }

    private func openExternalConnection(_ request: RemoteConnectionURL, in window: WindowModel) {
        switch request.kind {
        case .telnet:
            let host = Host(
                name: request.host, host: request.host,
                sshEnabled: false, telnetEnabled: true, telnetPort: request.port)
            window.openExternalTelnetSession(
                host: host, username: request.username,
                password: request.advisoryPassword.map(SSHSecret.init))
        case .ssh, .sftp:
            let host = Host(name: request.host, host: request.host, port: request.port)
            let route = SSHConnectionRoute(
                hosts: [host], usernames: request.username.map { [host.id: $0] } ?? [:])
            if request.kind == .ssh {
                let workspace = window.openSSHSession(
                    host: host, usernameHint: request.username, connectionRoute: route)
                workspace.focusedPane.sshSession?.connectionOrigin = .externalLink(
                    hostKeyConstraints: request.hostKeyFingerprint.map { [host.id: $0] } ?? [:])
                return
            }
            let workspace = window.openSFTPChannel(host: host)
            guard let channel = workspace.focusedPane.sftpChannel else { return }
            channel.configureExternalConnection(
                host: host, username: request.username, route: route,
                fingerprint: request.hostKeyFingerprint,
                resourcePath: request.path,
                mustBeDirectory: request.sftpType == .directory
            ) { [weak self, weak channel] file in
                guard let self, let channel else { return }
                channel.revealExternalFile(file)
                guard Self.canAutomaticallyOpenExternalSFTPFile(file) else {
                    channel.operationError = String(
                        localized: AppStrings.SFTP.executableFileWarning)
                    return
                }
                channel.open(file, coordinator: self.sftpTransfers, edits: self.sftpEdits) { localURL in
                    if NSWorkspace.shared.open(localURL) {
                        channel.recordOpenedFile(at: file.path)
                    }
                }
            }
        }
    }

    private static func canAutomaticallyOpenExternalSFTPFile(_ file: RemoteFile) -> Bool {
        guard file.kind == .file, file.permissions & 0o111 == 0 else { return false }
        let unsafeExtensions: Set<String> = [
            "app", "bash", "bin", "command", "dmg", "exe", "ksh", "mpkg", "pkg", "pl", "py", "rb",
            "sh", "tool", "zsh",
        ]
        return !unsafeExtensions.contains((file.name as NSString).pathExtension.lowercased())
    }

    /// Mark as recently used, and flip the status dot.
    ///
    /// Its own method because three code paths now open hosts — one, a batch of
    /// workspaces, and a batch into one Workspace — and *where it lands* is the only
    /// thing that should differ between them. Inlining this was fine while there
    /// were two.
    private func beginOpening(_ host: Host, as target: HostOpenTarget) {
        switch target {
        case .preferredTerminal, .sshSession, .telnetSession:
            hosts.setStatus(.connecting, for: host.id)
        case .sftpChannel:
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
    func recentHosts(limit: Int = 5, localOnly: Bool = false) -> [Host] {
        var seen = Set<Host.ID>()
        let entries = localOnly ? connectionHistory.localEntries() : connectionHistory.entries()
        return entries.compactMap { entry in
            guard seen.insert(entry.hostID).inserted else { return nil }
            return hosts.host(entry.hostID)
        }.prefix(limit).map { $0 }
    }

    func lastConnectedAt(for hostID: Host.ID) -> Date? {
        connectionHistory.mostRecentDate(for: hostID)
    }

    func lastConnectedLocallyAt(for hostID: Host.ID) -> Date? {
        connectionHistory.mostRecentLocalDate(for: hostID)
    }

    /// Opens multiple Hosts, with the layout chosen by the calling surface.
    ///
    /// The workspaces path is a loop over the singular `open` rather than its own code
    /// path; the Workspace path cannot be, since the whole point is that it makes
    /// one workspace. What both share is `beginOpening`, so the bookkeeping cannot
    /// drift between them.
    ///
    /// In the workspaces case each `open` selects the workspace it made, which would leave
    /// the *last* host in front — the one furthest from where the eye started.
    /// Landing on the first instead matches the order the list was read and
    /// ticked in, and the rest are a ⇧⌘] away.
    func open(
        _ hosts: [Host],
        as target: HostOpenTarget,
        layout: BatchLayout = .separateWorkspaces,
        in window: WindowModel
    ) {
        configureConnectionHistory(in: window)
        switch layout {
        case .separateWorkspaces:
            let opened = hosts.map { open($0, as: target, in: window) }
            if let first = opened.first { window.select(first.id) }
        case .oneWorkspace:
            for host in hosts { beginOpening(host, as: target) }
            window.openWorkspace(hosts, as: target)
        }
    }

    /// Turns Snippet execution into ordinary visible sessions rather than a
    /// hidden job. `overrideHostIDs` powers explicit host overrides; `fallbackHostIDs`
    /// is used only by snippets whose saved target list is empty.
    func execute(
        _ snippets: [Snippet], overrideHostIDs: [Host.ID]? = nil,
        fallbackHostIDs: [Host.ID]? = nil, in window: WindowModel
    ) {
        configureConnectionHistory(in: window)
        var opened: [Workspace] = []
        for snippet in snippets {
            let ids =
                overrideHostIDs
                ?? (snippet.targetHostIDs.isEmpty
                    ? (fallbackHostIDs ?? []) : snippet.targetHostIDs)
            let wanted = Set(ids)
            let targets = hosts.hosts(matching: "", for: .snippetExecution)
                .filter { wanted.contains($0.id) }
            guard !targets.isEmpty else { continue }
            for host in targets { beginOpening(host, as: .sshSession) }
            if let workspace = window.openSnippetWorkspace(
                hosts: targets, command: snippet.body
            ) {
                opened.append(workspace)
            }
        }
        if let first = opened.first { window.select(first.id) }
    }

    private func configureConnectionHistory(in window: WindowModel) {
        window.hostStore = hosts
        window.workspacePreferences = { [weak self] in
            self?.workspaceSettings.preferences ?? WorkspacePreferences()
        }
        window.recordConnectionHistory = { [weak self] hostID, kind in
            guard let self, self.hosts.host(hostID) != nil else { return nil }
            return self.connectionHistory.record(kind: kind, for: hostID)?.id
        }
        window.endConnectionHistory = { [weak self] id in
            self?.connectionHistory.end(id)
        }
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
    /// The sidebar, Welcome page and File menu raise this chooser. Confirmation
    /// opens the selected Hosts as panes of one new Workspace.
    func batchStartup(in window: WindowModel) {
        window.hostChooser = .batchStartup
    }

}
