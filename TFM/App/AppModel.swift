import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
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
    let knownHosts: KnownHostsLibraryModel
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
    let appReview: AppReviewController
    let serverMetrics: ServerMetricsModel
    var opensMetricsOnNextWindow = false
    let connections: RemoteConnectionCoordinator
    let serialPorts: any SerialPortServing
    let hostRepository: any HostRepository
    let settingsSync: SettingsSyncCoordinator?
    let metricsSync: MetricsSyncCoordinator?
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
    /// The procedures the user installed for the agent to follow. Its own store
    /// rather than more fields on `ai`: that one is about endpoints you spend a
    /// key at, this is a library of documents. See `SkillLibraryModel`.
    let terminalSettings: TerminalSettingsModel
    let skills: SkillLibraryModel
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
    private let agentBackgroundCommands: AgentBackgroundCommands
    private let outboxRunner: OutboxRunner?
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var deletedAgentConversationIDs = Set<UUID>()
    /// Conversations already handed to the summarizer. Titling is once per
    /// conversation, and every run re-arms the hook that would do it.

    func makeSSHImportModel() -> SSHImportModel {
        SSHImportModel(library: hosts, reader: SSHImportReader())
    }

    init(
        hosts: HostLibraryModel, ai: AIConfigurationModel = AIConfigurationModel(),
        skills: SkillLibraryModel = SkillLibraryModel(),
        terminalSettings: TerminalSettingsModel = TerminalSettingsModel(),
        commandHistory: CommandHistoryModel = CommandHistoryModel(),
        sftpHistory: SFTPHistoryModel = SFTPHistoryModel(),
        connectionHistory: ConnectionHistoryModel = ConnectionHistoryModel(),
        externalToolCalls: ToolAuditModel = ToolAuditModel(),
        dependencies: AppDependencies? = nil,
        speechTranscription: SpeechTranscriptionCoordinator? = nil,
        proAccess: ProAccessController = .unrestrictedForTesting(),
        onboarding: OnboardingController = OnboardingController(),
        appReview: AppReviewController = AppReviewController(),
        serverMetrics suppliedMetrics: ServerMetricsModel? = nil
    ) {
        let dependencies = dependencies ?? .inMemory(hosts: hosts.hosts, groups: hosts.groups)
        let connectionCoordinator = dependencies.connectionCoordinator
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
        self.externalToolCalls = externalToolCalls
        externalAuthentication = ExternalAuthCoordinator()
        connections = connectionCoordinator
        serialPorts = dependencies.serialPortService
        agentRunRepository = dependencies.agentRunRepository ?? InMemoryAgentRunRepository()
        let agentHostServices = AgentHostServices.live(store: hosts, coordinator: connectionCoordinator)
        agentHosts = agentHostServices.resolver
        agentAuthentication = agentHostServices.authentication
        agentConnections = agentHostServices.connections
        agentBackgroundCommands = agentHostServices.background
        hostRepository = dependencies.hostRepository
        vaultSync = dependencies.vaultSync
        settingsSync = dependencies.settingsSync
        metricsSync = dependencies.metricsSync
        forwarding = PortForwardingController(hosts: hosts, defaults: dependencies.forwardingDefaults)
        sftpTransfers = SFTPTransferCoordinator(
            store: hosts,
            clientFactory: { connectionCoordinator.makeSFTPClient() }
        )
        self.ai = ai
        self.skills = skills
        self.terminalSettings = terminalSettings
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
        hosts.willDeleteHost = { [weak forwarding, weak serverMetrics, agentConnections] hostID, ruleIDs in
            serverMetrics?.remove(hostID)
            forwarding?.suspend(ruleIDs)
            // Not a `HostDeletionOutbox` step like the others: a live socket
            // cannot outlive the process, so there is nothing to replay after a
            // crash and nothing to make durable.
            Task { await agentConnections.disconnect(hostID: hostID) }
        }
        hosts.willDeletePortForwardings = { [weak forwarding] ruleIDs in
            forwarding?.suspend(ruleIDs)
        }
        hosts.didReplacePortForwardings = { [weak forwarding] ruleIDs in
            forwarding?.resumeEnabled(ruleIDs)
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
            outboxRunner.registerHostDeletionHandlers(
                repository: hostRepository,
                closeWorkspaces: { [weak self] deletion in
                    self?.closeWorkspaces(for: deletion.hostID)
                },
                cancelTransfers: { [weak self] deletion in
                    self?.sftpTransfers.cancelAll(for: deletion.hostID)
                },
                stopForwardings: { [weak self] deletion in
                    self?.forwarding.remove(deletion.forwardingRuleIDs)
                }
            )
            outboxRunner.start()
        }
        vaultSync?.didApplyRemote = { [weak self] snapshot, keys in
            self?.applyRemoteVaultSnapshot(snapshot, changedKeys: keys)
        }
        terminalSettings.didChangeShellIntegration = { [weak self] enabled in
            self?.shellIntegrationPreferenceDidChange(isEnabled: enabled)
        }
        settingsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.ai.applyRemoteSnapshot(snapshot.configuration, webSearch: snapshot.webSearch)
            self?.skills.applyRemoteSnapshot(snapshot.skills)
            self?.terminalSettings.applyRemoteSnapshot(snapshot.terminal)
        }
        metricsSync?.didApplyRemote = { [weak serverMetrics] snapshot, _ in
            serverMetrics?.applyRemoteSnapshot(snapshot)
        }
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            metricsSync?.start()
            settingsSync?.start()
        }
    }

    func reconcileProAccess() {
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            metricsSync?.start()
            settingsSync?.start()
            mcpServer.resumeForProAccess()
        } else {
            vaultSync?.pause()
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
                sftpTransfers.cancelAll(for: change.id)
                commandHistory.clear(for: change.id)
                sftpHistory.clear(for: change.id)
                connectionHistory.clear(for: change.id)
            }
        }
        if !plan.forwardingRuleIDs.isEmpty { forwarding.suspend(plan.forwardingRuleIDs) }
        hosts.replacePersistedSnapshot(snapshot)
        forwarding.resumeEnabled()
    }

    @ObservationIgnored private lazy var assistantOperations = AssistantConversationOperations(
        repository: agentRunRepository)

    @ObservationIgnored private lazy var assistantExecution = AssistantExecutionController(
        ai: ai, skills: skills, repository: agentRunRepository,
        authorize: { [weak self] in self?.proAccess.require(.assistant) == true },
        makeRegistry: { [weak self] conversation, model, provider, skills, channel, includes in
            guard let self else { return AgentToolRegistry([AnyAgentTool]()) }
            return AssistantToolRegistry.make(
                conversation: conversation, model: model, provider: provider,
                skills: skills, channel: channel, ai: ai, hosts: agentHosts, metrics: serverMetrics,
                connections: agentConnections, authentication: agentAuthentication,
                background: agentBackgroundCommands, includesTerminalSuggestion: includes)
        },
        title: { [weak self] context in
            guard let self else { throw CancellationError() }
            return try await conversationTitles.summarize(context)
        })

    func sendAgentDraft(
        _ conversation: ConversationModel, context: SessionContext = .none,
        includesTerminalSuggestion: Bool = false
    ) {
        assistantExecution.sendAgentDraft(
            conversation, context: context, includesTerminalSuggestion: includesTerminalSuggestion)
    }

    func startAgentRun(
        _ conversation: ConversationModel, promptID: UUID? = nil, prompt: String? = nil,
        authoredPrompt: String? = nil, promptImages: [AgentImageAttachment]? = nil,
        promptContextAttachments: [AgentContextAttachment]? = nil,
        context: SessionContext? = nil, includesTerminalSuggestion: Bool = false
    ) {
        assistantExecution.startAgentRun(
            conversation, promptID: promptID, prompt: prompt,
            authoredPrompt: authoredPrompt, promptImages: promptImages,
            promptContextAttachments: promptContextAttachments,
            context: context, includesTerminalSuggestion: includesTerminalSuggestion)
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

    func registerWindow(_ window: WindowModel) {
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
                        window.isAssistantArchivePresented = true
                    }
                    if window.sidebar.assistantConversationID == id {
                        window.sidebar.assistantConversationID = nil
                        if wasArchived {
                            window.sidebar.isAssistantArchivePresented = true
                        }
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
            !conversation.isStreaming, !conversation.isCompacting,
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
        context: SessionContext, includesTerminalSuggestion: Bool, reportingTo window: WindowModel?
    ) {
        guard let conversation = conversation(id) else { return }
        Task { [weak window] in
            do {
                guard
                    let prompt = try await assistantOperations.edit(
                        conversation, messageID: messageID, text: value,
                        contextSnapshot: assistantExecution.contextSnapshot(
                            for: conversation, context: context,
                            includesTerminalSuggestion: includesTerminalSuggestion))
                else { return }
                startAgentRun(
                    conversation, promptID: prompt.id, prompt: prompt.text,
                    authoredPrompt: prompt.authoredText, promptImages: prompt.images,
                    promptContextAttachments: prompt.contextAttachments,
                    context: context, includesTerminalSuggestion: includesTerminalSuggestion)
            } catch { window?.assistantOperationError = error.localizedDescription }
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
        serverMetrics.shutdown()
        speechTranscription.cancelAll()
        let liveWindows = windows.values.compactMap(\.value)
        windows.removeAll()
        for window in liveWindows { window.closeAll() }
        sftpTransfers.cancelAll()
        forwarding.suspendAll()
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
    /// ticked in, and the rest are a ⇧⌘] away.
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
