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
    case moshSession
    case eternalTerminalSession
    case telnetSession
    case sftpChannel

    static func terminal(_ transport: HostTerminalProtocol) -> Self {
        switch transport {
        case .ssh: .sshSession
        case .mosh: .moshSession
        case .eternalTerminal: .eternalTerminalSession
        case .telnet: .telnetSession
        }
    }

    func connectionKind(for host: Host) -> ConnectionHistoryEntry.Kind? {
        switch self {
        case .preferredTerminal: .preferredTerminal(for: host)
        case .sshSession: .ssh
        case .moshSession: .mosh
        case .eternalTerminalSession: .eternalTerminal
        case .telnetSession: .telnet
        case .sftpChannel: .sftp
        }
    }

    func accessProtocol(for host: Host) -> HostTerminalProtocol {
        connectionKind(for: host) == .telnet ? .telnet : .ssh
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
    private var terminationTask: Task<Void, Never>?
    private var isTerminating = false

    var hasOpenWorkspaces: Bool {
        windows.values.contains { entry in
            guard let window = entry.value, !window.isClosed else { return false }
            return !window.workspaces.isEmpty
        }
    }

    var hasUnsavedTerminalThemes: Bool {
        windows.values.contains {
            guard let window = $0.value, !window.isClosed else { return false }
            return window.hasUnsavedTerminalThemeChanges
        }
    }

    func saveTerminalThemeChanges() {
        for entry in windows.values {
            guard let window = entry.value, !window.isClosed else { continue }
            window.saveTerminalThemeChanges()
        }
    }

    private final class WeakWindow {
        weak var value: WindowModel?
        init(_ value: WindowModel) { self.value = value }
    }
    private final class WeakAssistantChatCoordinator {
        weak var value: AssistantChatCoordinator?
    }

    private let hosts: HostLibraryModel
    let proAccess: ProAccessController
    let tailscale: TailscaleModel
    var hostLibrary: HostLibraryModel { hosts }
    let knownHosts: KnownHostsLibraryModel
    let credentials: CredentialLibraryModel
    let snippets: SnippetLibraryModel
    let forwardings: ForwardingLibraryModel
    let connectionHistory: ConnectionHistoryModel
    let devices: DeviceDirectoryModel
    private let externalToolCalls: ToolAuditModel
    var toolAudit: ToolAuditModel { externalToolCalls }
    let externalAuthentication: ExternalAuthCoordinator
    let mcpServer: MCPServerController
    let commands = AppCommandRegistry()
    let onboarding: OnboardingController
    let appReview: AppReviewController
    let diagnosis: DiagnosisController
    let serverMetrics: ServerMetricsModel
    let windowSizeStore: MainWindowSizeStore
    let logging: any ApplicationLogManaging
    let notifications = SystemNotifications()
    let notificationSettings: NotificationSettingsModel
    @ObservationIgnored private lazy var notificationRouter = DesktopNotificationRouter(app: self)
    @ObservationIgnored private var notificationBadge: NotificationBadgeCoordinator?
    @ObservationIgnored private lazy var terminalNotifications = TerminalNotificationCoordinator(
        service: notifications,
        preferences: { [weak self] in self?.notificationSettings.preferences ?? .init() },
        isFocused: { [weak self] in self?.isTerminalNotificationFocused($0) ?? false },
        title: { [weak self] id in
            guard let self, let (_, workspace, _) = self.commandNotificationTarget(id) else { return nil }
            return workspace.title(in: self.hostLibrary, locale: .current)
        },
        body: CommandNotificationContent.body,
        ringBell: TerminalNotificationPlatform.ringBell)

    @ObservationIgnored private lazy var assistantNotifications = AssistantNotificationCoordinator(
        service: notifications,
        preferences: { [weak self] in self?.notificationSettings.preferences ?? .init() },
        isFocused: { [weak self] in self?.isAssistantNotificationFocused($0) ?? false },
        isVisible: { [weak self] in self?.isAssistantConversationVisible($0) ?? false },
        content: AssistantNotificationContent.make)

    @ObservationIgnored lazy var mainWindows = MainWindowCoordinator(app: self, sizes: windowSizeStore)
    let connections: RemoteConnectionCoordinator
    let persistentSessionCloser: RemoteSessionCloseCoordinator
    let serialPorts: any SerialPortServing
    let hostRepository: any HostRepository
    let settingsSync: SettingsSyncCoordinator?
    let metricsSync: MetricsSyncCoordinator?
    let vaultSync: VaultSyncCoordinator?
    let connectionHistorySync: ConnectionHistorySyncCoordinator?
    let deviceSync: DeviceSyncCoordinator?
    let forwarding: PortForwardingController
    let sftpEdits: SFTPEditService
    let sftpTransfers: SFTPTransferCoordinator
    @ObservationIgnored private var sftpNotifications: SFTPNotificationCoordinator?
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
    let terminalExperienceSettings: TerminalExperienceSettingsModel
    private let terminalBellSound: @MainActor () -> Void
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
    let assistantModelSelections: AssistantModelSelectionController
    private let assistantChatCollaborationStore: any AssistantChatCollaborationStoring
    @ObservationIgnored private let assistantChatCoordinatorBox = WeakAssistantChatCoordinator()
    private let agentHosts: AgentHostResolver
    private let agentConnections: AgentConnectionPool
    private let agentAuthentication: AgentSSHAuthenticationRegistry
    /// Commands that outlived the turn that started them. App-wide rather than
    /// per-run, because a handle taken in one turn is answered in a later one
    /// and a run ending is not a reason to stop a deploy.
    private let agentBackgroundCommands: AgentBackgroundCommands
    private let outboxRunner: OutboxRunner?
    private let snippetTimestampFallback: Date
    var closedWorkspaceInstances: [UUID: [Workspace]] = [:]
    let recentlyClosedStore: RecentlyClosedStore<RecentlyClosedRecord<ClosedWorkspaceRecord>>
    private let settingsDefaults: UserDefaults
    private let shutdownDependencies: AppShutdownDependencies?
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var deletedAgentConversationIDs = Set<UUID>()
    /// Conversations already handed to the summarizer. Titling is once per
    /// conversation, and every run re-arms the hook that would do it.

    func snippetModifiedAt(for snippetID: Snippet.ID) -> Date {
        SnippetTimestamp.resolve(
            modifiedAt: snippets.modifiedAt(for: snippetID), fallback: snippetTimestampFallback)
    }

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
        terminalBellSound: @escaping @MainActor () -> Void = TerminalNotificationPlatform.ringBell,
        notificationSettings: NotificationSettingsModel = NotificationSettingsModel(),
        sshSettings: SSHSettingsModel = SSHSettingsModel(),
        sftpSettings: SFTPSettingsModel = SFTPSettingsModel(),
        workspaceSettings: WorkspaceSettingsModel = WorkspaceSettingsModel(),
        connectionHistory: ConnectionHistoryModel = ConnectionHistoryModel(),
        devices: DeviceDirectoryModel? = nil,
        tailscaleStore: (any TailscaleLocalStoring)? = nil,
        tailscaleFactory: @escaping TailscaleNodeFactory = { _, _, _, _ in
            throw TailscaleConfigurationError.unavailable
        },
        tailscaleProfileStorage: TailscaleProfileStorage = .disabled,
        externalToolCalls: ToolAuditModel = ToolAuditModel(),
        dependencies: AppDependencies? = nil,
        speechTranscription: SpeechTranscriptionCoordinator? = nil,
        proAccess: ProAccessController = .unrestrictedForTesting(),
        onboarding: OnboardingController = OnboardingController(),
        appReview: AppReviewController = AppReviewController(),
        diagnosis: DiagnosisController = DiagnosisController(),
        serverMetrics suppliedMetrics: ServerMetricsModel? = nil,
        windowSizeStore: MainWindowSizeStore = MainWindowSizeStore()
    ) {
        self.windowSizeStore = windowSizeStore
        let dependencies = dependencies ?? .inMemory(hosts: hosts.hosts, groups: hosts.groups)
        settingsDefaults = dependencies.settingsDefaults
        terminalExperienceSettings = TerminalExperienceSettingsModel(defaults: dependencies.settingsDefaults)
        self.terminalBellSound = terminalBellSound
        recentlyClosedStore = RecentlyClosedStore(
            defaults: dependencies.settingsDefaults, key: "desktop.recentlyClosed.v2")
        snippetTimestampFallback = SnippetTimestamp.fallback(in: dependencies.settingsDefaults)
        assistantConversations = dependencies.assistantConversations ?? AssistantConversationStore()
        shutdownDependencies = dependencies.shutdown
        logging = dependencies.logging
        let externalAuthentication = ExternalAuthCoordinator(
            logger: logging.makeLogger(label: "termind.external-mcp"))
        self.externalAuthentication = externalAuthentication
        let connectionCoordinator = dependencies.connectionCoordinator.withKeyboardInteractive(
            externalAuthentication.keyboardInteractive)
        connectionCoordinator.updateAgentForwarding(
            VaultSSHAgent.factory(library: hosts, securityKeySigning: externalAuthentication.securityKeySigning))
        connectionCoordinator.updateSSHPreferences(sshSettings.preferences)
        self.serverMetrics =
            suppliedMetrics
            ?? ServerMetricsModel(
                hosts: hosts, preferences: dependencies.metricsPreferences ?? MetricsPreferences(),
                makeSampler: { connectionCoordinator.makeMetricsSampler() }
            )
        self.hosts = hosts
        hosts.hostAccess.entitlement = proAccess.status
        hosts.requestHostUpgrade = { proAccess.presentPaywall() }
        hosts.resolveInitialHostEntitlement = { [weak hosts] in
            await proAccess.refresh()
            hosts?.hostAccess.entitlement = proAccess.status
        }
        self.proAccess = proAccess
        hosts.wakeOnLAN = WakeOnLANController(
            sender: LANWakeOnLANSender())
        let wakeLogger = dependencies.logging.makeLogger(label: "termind.wake-on-lan")
        hosts.wakeOnLAN?.reportAutomaticFailure = { _ in wakeLogger.warning("wake.automatic.failed") }
        self.onboarding = onboarding
        self.appReview = appReview
        self.diagnosis = diagnosis
        knownHosts = KnownHostsLibraryModel(library: hosts)
        credentials = CredentialLibraryModel(library: hosts)
        snippets = SnippetLibraryModel(library: hosts)
        forwardings = ForwardingLibraryModel(library: hosts)
        self.connectionHistory = connectionHistory
        let devices = devices ?? DeviceDirectoryModel(currentDeviceID: connectionHistory.sourceDeviceID)
        self.devices = devices
        tailscale = TailscaleModel(
            library: hosts, store: tailscaleStore ?? InMemoryTailscaleLocalStore(),
            factory: tailscaleFactory, profileStorage: tailscaleProfileStorage,
            hostname: { devices.currentDeviceName }, hasAccess: { proAccess.canUse(.tailscale) }
        )
        self.externalToolCalls = externalToolCalls
        connections = connectionCoordinator
        let sessionTerminator = RemoteSessionTerminator.live(coordinator: connectionCoordinator)
        persistentSessionCloser = RemoteSessionCloseCoordinator { [hosts] request in
            try await sessionTerminator.terminate(request, hosts: hosts)
        }
        serialPorts = dependencies.serialPortService
        agentRunRepository = MemoryIndexedAgentRepository(
            base: dependencies.agentRunRepository ?? InMemoryAgentRunRepository(), memory: memory)
        assistantModelSelections = AssistantModelSelectionController(
            ai: ai,
            store: dependencies.assistantModelSelectionStore ?? InMemoryAssistantModelSelectionStore())
        assistantChatCollaborationStore =
            dependencies.assistantChatCollaborationStore ?? InMemoryAssistantChatCollaborationStore()
        let sftpPreferences = MultiConnectionPolicy(
            allowsMultipleConnections: proAccess.canUse(.sftpMultiConnection)
        ).sftpPreferences(sftpSettings.preferences)
        let sftpConcurrencyScheduler = SFTPConcurrencyScheduler(preferences: sftpPreferences)
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
        connectionHistorySync = dependencies.connectionHistorySync
        deviceSync = dependencies.deviceSync
        settingsSync = dependencies.settingsSync
        metricsSync = dependencies.metricsSync
        forwarding = PortForwardingController(
            hosts: hosts, poolPolicy: .hostConfigured,
            connectionLimit: MultiConnectionPolicy(
                allowsMultipleConnections: proAccess.canUse(.portForwardingMultiConnection)
            ).forwardingConnections(Host.portForwardingMaxConnectionsRange.upperBound),
            logger: dependencies.logging.makeLogger(label: "termind.port-forwarding"))
        sftpTransfers = SFTPTransferCoordinator(
            store: hosts,
            clientFactory: { connectionCoordinator.makeSFTPClient() },
            globalLimit: sftpPreferences.globalLimit,
            perHostLimit: sftpPreferences.perHostLimit,
            strategy: sftpPreferences.strategy,
            concurrencyScheduler: sftpConcurrencyScheduler
        )
        sftpEdits = SFTPEditService(transfers: sftpTransfers, host: { [weak hosts] in hosts?.host($0) })
        self.ai = ai
        self.skills = skills
        self.memory = memory
        self.terminalSettings = terminalSettings
        self.notificationSettings = notificationSettings
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
            externalAuthentication: externalAuthentication, history: externalToolCalls
        )
        agentHosts.configureTemporaryTargets(
            targets: { [weak self] in self?.temporaryAgentTargets() ?? [] },
            configuration: { [weak self] hostID in
                self?.temporaryAgentConfiguration(for: hostID)
            }
        )
        hosts.willDeleteHost = {
            [weak forwarding, weak mcpServer, agentConnections, weak sftpEdits] hostID, ruleIDs in
            sftpEdits?.invalidate(hostID: hostID)
            mcpServer?.tools.revokeHost(hostID)
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
            repository.didRecordHistoryChanges = { [weak connectionHistorySync = dependencies.connectionHistorySync] in
                connectionHistorySync?.noteLocalChanges($0)
            }
            repository.didRecordVaultChanges = { [weak vaultSync = dependencies.vaultSync] mutations in
                vaultSync?.noteLocalChanges(mutations)
            }
        }
        if let outboxRunner {
            outboxRunner.registerHostDeletionHandlers(
                repository: hostRepository,
                closeWorkspaces: { [weak self] deletion in
                    self?.serverMetrics.remove(deletion.hostID)
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
        connectionHistorySync?.didApplyRemote = { [weak self] _ in self?.connectionHistory.reload() }
        deviceSync?.didApplyRemote = { [weak self] _ in self?.devices.reload() }
        vaultSync?.didApplyRemote = { [weak self] snapshot, keys in
            self?.applyRemoteVaultSnapshot(snapshot, changedKeys: keys)
        }
        sftpSettings.didChange = { [weak self] _ in
            self?.reconcileSFTPPreferences()
        }
        hosts.didDeleteTailscaleGroups = { [weak self] groups, hostIDs in
            guard let self else { return }
            self.serverMetrics.removeTailscaleGroups(groups)
            for id in hostIDs {
                self.closeWorkspaces(for: id)
                self.sftpEdits.invalidate(hostID: id)
                self.sftpTransfers.cancelAll(for: id)
                self.serverMetrics.remove(id)
            }
        }
        tailscale.start()
        proAccess.accessDidChange = { [weak self] in
            self?.reconcileProAccess()
            self?.tailscale.reconcile()
            self?.serverMetrics.reconcile()
            self?.reconcileConnectionPreferences()
        }
        sshSettings.didChange = { preferences in
            connectionCoordinator.updateSSHPreferences(preferences)
        }
        notifications.onOpen = { [weak self] target in self?.notificationRouter.open(target) }
        sftpNotifications = SFTPNotificationCoordinator(
            service: notifications, initialTransfers: hosts.sftpTransfers,
            preferences: { [weak self] in self?.notificationSettings.preferences ?? .init() },
            isFocused: {
                NSApp.isActive && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey }
            },
            content: SFTPNotificationContent.make)
        hosts.sftpTransferStateDidChange = { [weak self] in self?.sftpNotifications?.receive($0) }
        hosts.sftpTransfersDidRemove = { [weak self] in self?.sftpNotifications?.forgetFinishedTransfers($0) }
        notificationBadge = NotificationBadgeCoordinator(service: notifications) { [weak self] in
            guard let self, self.notificationSettings.preferences.isEnabled else { return 0 }
            return self.unreadNotificationCount
        }
        ai.didChange = { [weak self] in self?.repairUnavailableAssistantModels() }
        settingsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.ai.applyRemoteSnapshot(snapshot.configuration, webSearch: snapshot.webSearch)
            self?.skills.applyRemoteSnapshot(snapshot.skills)
            self?.terminalSettings.applyRemoteSnapshot(snapshot.terminal)
            self?.terminalSettings.applyRemoteThemes(snapshot.terminalThemes)
            self?.sshSettings.applyRemoteSnapshot(snapshot.ssh)
            self?.sftpSettings.applyRemoteSnapshot(snapshot.sftp)
            self?.workspaceSettings.applyRemoteSnapshot(snapshot.workspace)
            self?.notificationSettings.applyRemoteSnapshot(snapshot.notifications)
        }
        metricsSync?.didApplyRemote = { [weak serverMetrics] snapshot, _ in
            serverMetrics?.applyRemoteSnapshot(snapshot)
        }
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            connectionHistorySync?.start()
            deviceSync?.start()
            metricsSync?.start()
            settingsSync?.start()
        }
        _ = assistantChatCoordinator
    }

    private func reconcileConnectionPreferences() {
        reconcileSFTPPreferences()
        let forwardingPolicy = MultiConnectionPolicy(
            allowsMultipleConnections: proAccess.canUse(.portForwardingMultiConnection))
        forwarding.updateConnectionLimit(
            forwardingPolicy.forwardingConnections(Host.portForwardingMaxConnectionsRange.upperBound))
    }

    private func reconcileSFTPPreferences() {
        let policy = MultiConnectionPolicy(allowsMultipleConnections: proAccess.canUse(.sftpMultiConnection))
        sftpTransfers.updatePreferences(policy.sftpPreferences(sftpSettings.preferences))
    }

    private func repairUnavailableAssistantModels() {
        do {
            try assistantModelSelections.repairUnavailable(in: assistantConversations.conversations)
        } catch {
            for window in windows.values.compactMap(\.value) {
                window.assistantOperationError = error.localizedDescription
            }
        }
    }

    func reconcileProAccess() {
        hosts.hostAccess.entitlement = proAccess.status
        if proAccess.canUse(.vaultSync) {
            vaultSync?.start()
            connectionHistorySync?.start()
            deviceSync?.start()
            metricsSync?.start()
            settingsSync?.start()
        } else {
            vaultSync?.pause()
            connectionHistorySync?.pause()
            deviceSync?.pause()
            metricsSync?.pause()
            settingsSync?.pause()
        }
    }

    private func applyRemoteVaultSnapshot(
        _ snapshot: VaultSnapshot, changedKeys: Set<VaultRecordKey>
    ) {
        let retainedHostIDs = Set(snapshot.hosts.map(\.id))
        for key in changedKeys where key.kind == .host && !retainedHostIDs.contains(key.id) {
            serverMetrics.remove(key.id)
        }
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
                serverMetrics.remove(change.id)
                closeWorkspaces(for: change.id)
                sftpEdits.invalidate(hostID: change.id)
                sftpTransfers.cancelAll(for: change.id)
                externalAuthentication.cancel(hostID: change.id)
                mcpServer.tools.revokeHost(change.id)
                connectionHistory.clear(for: change.id)
            }
        }
        if !plan.forwardingRuleIDs.isEmpty { forwarding.stop(plan.forwardingRuleIDs) }
        hosts.replacePersistedSnapshot(snapshot)
        forwarding.reconcileConfiguration()
    }

    @ObservationIgnored private lazy var assistantOperations = AssistantConversationOperations(
        repository: agentRunRepository, modelSelections: assistantModelSelections)

    @ObservationIgnored private lazy var assistantExecution = AssistantExecutionController(
        ai: ai, skills: skills, repository: agentRunRepository, memory: memory,
        modelSelections: assistantModelSelections,
        reportModelSelectionError: { [weak self] message in
            for window in self?.windows.values.compactMap(\.value) ?? [] {
                window.assistantOperationError = message
            }
        },
        observeNotifications: { [weak self] in self?.assistantNotifications.observe($0) },
        authorize: { [weak self] in
            guard let self, !self.isTerminating else { return false }
            return true
        },
        makeRegistry: { [weak self] conversation, model, provider, skills, channel, panes, source in
            guard let self else { return AgentToolRegistry([AnyAgentTool]()) }
            return AssistantToolRegistry.make(
                conversation: conversation, model: model, provider: provider,
                skills: skills, channel: channel, ai: ai, hosts: agentHosts, metrics: serverMetrics,
                connections: agentConnections, authentication: agentAuthentication,
                background: agentBackgroundCommands, panes: panes,
                chatModels: assistantChatCoordinatorBox.value, chats: assistantChatCoordinatorBox.value,
                chatSource: source)
        },
        title: { [weak self] context in
            guard let self else { throw CancellationError() }
            return try await conversationTitles.summarize(context)
        },
        logger: logging.makeLogger(label: "termind.agent"))

    @ObservationIgnored private lazy var assistantChatCoordinator: AssistantChatCoordinator = {
        let coordinator = AssistantChatCoordinator(
            conversations: assistantConversations, ai: ai,
            modelSelections: assistantModelSelections,
            collaborationStore: assistantChatCollaborationStore,
            prepareDelivery: { [weak self] text, origin, conversation in
                self?.assistantExecution.prepareIncomingAgentMessage(
                    text, origin: origin, in: conversation)
            },
            persistDelivery: { [weak self] prepared, conversation in
                guard let self else { throw CancellationError() }
                try await self.assistantExecution.persistPreparedAgentDelivery(
                    prepared, in: conversation)
            },
            startDelivery: { [weak self] prepared, conversation in
                self?.assistantNotifications.observe(conversation)
                self?.assistantExecution.startPreparedAgentDelivery(prepared, in: conversation)
            },
            cancelDelivery: { [weak self] prepared, conversation in
                await self?.assistantExecution.cancelPreparedAgentDelivery(
                    prepared, in: conversation)
            })
        assistantChatCoordinatorBox.value = coordinator
        return coordinator
    }()

    func sendAgentDraft(
        _ conversation: ConversationModel, context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false, window: WindowModel? = nil
    ) {
        assistantExecution.sendAgentDraft(
            conversation, context: context, terminalSuggestionsAvailable: terminalSuggestionsAvailable,
            panes: paneAccess(for: window))
    }

    @discardableResult
    func sendNewAgentConversation(
        _ conversation: ConversationModel, in library: AssistantLibraryModel,
        context: SessionContext = .none, terminalSuggestionsAvailable: Bool = false,
        window: WindowModel? = nil
    ) -> ConversationModel? {
        assistantExecution.sendNewConversation(
            conversation, in: library, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: paneAccess(for: window))
    }

    @discardableResult
    func sendNewAgentDraft(
        in library: AssistantLibraryModel, context: SessionContext = .none,
        terminalSuggestionsAvailable: Bool = false, window: WindowModel? = nil
    ) -> ConversationModel? {
        assistantExecution.sendDraftConversation(
            in: library, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: paneAccess(for: window))
    }

    @discardableResult
    func sendAgentText(
        _ text: String, in conversation: ConversationModel,
        context: SessionContext = .none, terminalSuggestionsAvailable: Bool = false,
        window: WindowModel? = nil
    ) -> Bool {
        assistantExecution.sendAgentText(
            text, in: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: paneAccess(for: window))
    }

    @discardableResult
    func sendPlanImplementation(
        _ card: AgentPlanCard, in conversation: ConversationModel,
        context: SessionContext = .none, terminalSuggestionsAvailable: Bool = false,
        window: WindowModel? = nil
    ) -> Bool {
        assistantExecution.sendPlanImplementation(
            card, in: conversation, context: context,
            terminalSuggestionsAvailable: terminalSuggestionsAvailable, panes: paneAccess(for: window))
    }

    func startAgentRun(
        _ conversation: ConversationModel, promptID: UUID? = nil, prompt: String? = nil,
        authoredPrompt: String? = nil, promptImages: [AgentImageAttachment]? = nil,
        promptContextAttachments: [AgentContextAttachment]? = nil,
        window: WindowModel? = nil
    ) {
        assistantExecution.startAgentRun(
            conversation, promptID: promptID, prompt: prompt,
            authoredPrompt: authoredPrompt, promptImages: promptImages,
            promptContextAttachments: promptContextAttachments,
            panes: paneAccess(for: window))
    }

    func paneAccess(for source: WindowModel?) -> AgentPaneAccess {
        AgentPaneAccess(
            list: { [weak self, weak source] in
                self?.openTerminalPanes(source: source)
                    .filter { $0.pane.status == .connected && $0.pane.readViewportText() != nil }
                    .map(\.metadata) ?? []
            },
            read: { [weak self, weak source] id in
                guard let match = self?.openTerminalPanes(source: source).first(where: { $0.metadata.id == id })
                else { return .closed }
                guard match.pane.status == .connected else { return .notConnected }
                let owner: PersistentTerminalViewOwner?
                switch match.pane.content {
                case .sshSession(let session): owner = session.terminalViewOwner
                case .telnetSession(let session): owner = session.terminalViewOwner
                case .serialSession(let session): owner = session.terminalViewOwner
                case .sftpChannel, .empty: return .closed
                }
                guard let text = owner?.readViewportText() else { return .noSurface }
                return .text(match.metadata, text)
            })
    }

    private func openTerminalPanes(source: WindowModel?) -> [(metadata: AgentPaneAccess.Pane, pane: Pane)] {
        windows.values.compactMap(\.value).filter { !$0.isClosed }.flatMap { window in
            window.workspaces.flatMap { workspace in
                workspace.panes.compactMap { pane in
                    guard pane.sshSession != nil || pane.telnetSession != nil || pane.serialSession != nil
                    else { return nil }
                    let isSelected = window.selectedWorkspace === workspace && workspace.focusedPaneID == pane.id
                    let isCurrent = window === source && isSelected
                    let metadata = AgentPaneAccess.Pane(
                        id: pane.id,
                        title: workspace.isSplit ? pane.title(in: hosts) : workspace.title(in: hosts),
                        hostID: pane.hostID,
                        workspace: workspace.title(in: hosts),
                        window: window.id.uuidString,
                        isActive: isSelected,
                        isCurrent: isCurrent
                    )
                    return (metadata, pane)
                }
            }
        }
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
        window.persistentSessionCloser = persistentSessionCloser
        window.hostStore = hosts
        window.rememberClosedWorkspace = { [weak self] in self?.rememberClosedWorkspaces([$0]) }
        window.rememberClosedWindow = { [weak self] workspaces, selected in
            self?.rememberClosedWorkspaces(workspaces, isWindow: true, selectedID: selected)
        }
        window.metricsModel = serverMetrics
        windows = windows.filter { $0.value.value != nil }
        windows[ObjectIdentifier(window)] = WeakWindow(window)
        window.assistantLibrary.adopt(assistantConversations)
        window.assistantLibrary.modelSelections = assistantModelSelections
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
            do {
                let restored = try await agentRunRepository.loadConversations()
                guard window?.isClosed == false else { return }
                try self?.restoreAssistantConversations(restored)
                self?.notificationRouter.resume()
            } catch {
                window?.assistantOperationError = error.localizedDescription
            }
        }
    }

    var notificationWindows: [WindowModel] { windows.values.compactMap(\.value).filter { !$0.isClosed } }

    func restoreAssistantConversations() async throws {
        try restoreAssistantConversations(await agentRunRepository.loadConversations())
    }

    private func restoreAssistantConversations(_ restored: [StoredAgentConversation]) throws {
        guard !isTerminating else { return }
        let visible = restored.filter { !deletedAgentConversationIDs.contains($0.id) }
        let selections = try assistantModelSelections.selectionsForRestore(visible)
        assistantConversations.restore(visible, modelSelections: selections)
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
                terminalSuggestionsAvailable: terminalSuggestionsAvailable,
                panes: paneAccess(for: window))
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
        guard hosts.host(hostID)?.isTailscaleManaged != true else { return false }
        do {
            try hostRepository.requestHostDeletion(hostID)
            serverMetrics.remove(hostID)
            forwarding.hostConfigurationChanged(hostID)
            forwarding.remove(hosts.portForwardings(for: hostID).map(\.id))
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
            let affected = hosts.hosts(inTreeOf: groupID).filter { !$0.isTailscaleManaged }
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
        persistentSessionCloser.cancelAll()
        notificationBadge?.stop()
        sftpNotifications?.stop()
        assistantNotifications.stop()
        terminalNotifications.stop()
        notificationRouter.stop()
        NSApp.dockTile.badgeLabel = nil
        if let terminationTask { return terminationTask }
        let conversations = assistantConversations.conversations
        let preparationCancellation = assistantExecution.cancelPendingRuns()
        for conversation in conversations { conversation.stop() }
        let conversationDrains = conversations.map { conversation in
            Task { @MainActor in await conversation.stopAndWait() }
        }
        let task = Task {
            [shutdownDependencies, mcpServer, sftpTransfers, agentBackgroundCommands, agentConnections, tailscale] in
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
            await tailscale.shutdown()
        }
        terminationTask = task
        memory.suspend()
        sftpEdits.setMonitoring(false)
        serverMetrics.shutdown()
        speechTranscription.cancelAll()
        let liveWindows = windows.values.compactMap(\.value)
        windows.removeAll()
        for window in liveWindows { window.closeAll(intent: .applicationTermination) }
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
    ) -> Workspace? {
        guard let kind = target.connectionKind(for: host) else { return nil }
        guard
            admitHostOpen(
                host, protocol: target.accessProtocol(for: host), in: window,
                whenResolved: { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.open(host, as: target, in: window)
                })
        else { return nil }
        configureConnectionHistory(in: window)
        beginOpening(host, as: target)

        switch kind {
        case .ssh: return window.openSSHSession(host: host)
        case .mosh: return window.openSSHSession(host: host, transport: .mosh)
        case .eternalTerminal: return window.openSSHSession(host: host, transport: .eternalTerminal)
        case .telnet: return window.openTelnetSession(host: host)
        case .sftp: return window.openSFTPChannel(host: host)
        }
    }

    @discardableResult
    func openQuickConnect(_ target: QuickConnectTarget, in window: WindowModel) -> Workspace? {
        if target.isSaved {
            return open(
                target.host,
                as: .terminal(target.connectionProtocol),
                in: window)
        }
        for node in target.route.hosts {
            guard
                admitHostOpen(
                    node, protocol: target.connectionProtocol, in: window,
                    whenResolved: { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.openQuickConnect(target, in: window)
                    })
            else { return nil }
        }
        for id in target.route.sourceHostIDs.values {
            if let saved = hosts.host(id),
                !admitHostOpen(
                    saved, protocol: target.connectionProtocol, in: window,
                    whenResolved: { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.openQuickConnect(target, in: window)
                    })
            {
                return nil
            }
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
    func saveQuickConnect(_ target: QuickConnectTarget) async throws -> Host {
        do {
            return try commitQuickConnect(target)
        } catch HostAccessError.verifyingEntitlement {
            await proAccess.refresh()
            hosts.hostAccess.entitlement = proAccess.status
            try Task.checkCancellation()
            return try commitQuickConnect(target)
        }
    }

    private func commitQuickConnect(_ target: QuickConnectTarget) throws -> Host {
        if target.connectionProtocol == .telnet {
            var host = target.host
            host.sshEnabled = false
            host.telnetEnabled = true
            try hosts.requireSavingHosts([host])
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
                channel.open(file, coordinator: self.sftpTransfers, edits: self.sftpEdits) {
                    [history = channel.history] localURL in
                    if NSWorkspace.shared.open(localURL) {
                        history.record(kind: .file, path: file.path)
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

    /// Optimistically shows connecting until the session reports its own state.
    ///
    /// Its own method because three code paths now open hosts — one, a batch of
    /// workspaces, and a batch into one Workspace — and *where it lands* is the only
    /// thing that should differ between them.
    private func beginOpening(_ host: Host, as target: HostOpenTarget) {
        switch target {
        case .preferredTerminal, .sshSession, .moshSession, .eternalTerminalSession, .telnetSession:
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
        }
    }

    /// Clears the global connection timeline and the Recents projection it
    /// supersedes in the History sidebar.
    func clearConnectionHistory() {
        connectionHistory.clearAll()
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
        let eligibleHosts = hosts.filter { target.connectionKind(for: $0) != nil }
        if let pending = eligibleHosts.first(where: {
            do {
                try self.hosts.requireHostAccess($0, protocol: target.accessProtocol(for: $0))
                return false
            } catch {
                return (error as? HostAccessError) == .verifyingEntitlement
            }
        }) {
            _ = admitHostOpen(pending, protocol: target.accessProtocol(for: pending), in: window) {
                [weak self, weak window] in
                guard let self, let window else { return }
                self.open(hosts, as: target, layout: layout, in: window)
            }
            return
        }
        let hosts = eligibleHosts.filter { admitHostOpen($0, protocol: target.accessProtocol(for: $0), in: window) }
        guard !hosts.isEmpty else { return }
        configureConnectionHistory(in: window)
        switch layout {
        case .separateWorkspaces:
            let opened = hosts.compactMap { open($0, as: target, in: window) }
            if let first = opened.first { window.select(first.id) }
        case .oneWorkspace:
            for host in hosts { beginOpening(host, as: target) }
            window.openWorkspace(hosts, as: target)
        }
    }

    private func admitHostOpen(
        _ host: Host, protocol connectionProtocol: HostTerminalProtocol,
        in window: WindowModel, whenResolved: (() -> Void)? = nil
    ) -> Bool {
        do {
            try hosts.requireHostAccess(host, protocol: connectionProtocol)
            return true
        } catch {
            if case HostAccessError.verifyingEntitlement = error {
                Task { [weak self, weak window] in
                    guard let self, let window else { return }
                    do {
                        try await hosts.resolveHostAccess(host, protocol: connectionProtocol)
                        whenResolved?()
                    } catch {
                        if case HostAccessError.lockedHost = error {
                            proAccess.presentPaywall()
                        } else if !(error is CancellationError) {
                            window.hostAccessError = HostAccessError.presentationDescription(of: error)
                        }
                    }
                }
            } else if case HostAccessError.lockedHost = error {
                proAccess.presentPaywall()
            } else {
                window.hostAccessError = HostAccessError.presentationDescription(of: error)
            }
            return false
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
            for host in targets { beginOpening(host, as: .preferredTerminal) }
            if let workspace = window.openSnippetWorkspace(
                hosts: targets, command: snippet.body
            ) {
                opened.append(workspace)
            }
        }
        if let first = opened.first { window.select(first.id) }
    }

    func isAssistantNotificationFocused(_ id: UUID) -> Bool {
        windows.values.compactMap(\.value).contains {
            !$0.isClosed && ($0.selectedDestination == .assistant || $0.isShowingAssistant(id))
        }
    }

    private func isAssistantConversationVisible(_ id: UUID) -> Bool {
        windows.values.compactMap(\.value).contains { $0.isShowingAssistant(id) }
    }

    var unreadAssistantNotificationCount: Int {
        assistantConversations.conversations.filter { !$0.isArchived }.reduce(0) { $0 + $1.unreadNotificationCount }
    }

    var unreadNotificationCount: Int {
        unreadAssistantNotificationCount
            + windows.values.compactMap(\.value).filter { !$0.isClosed }
            .reduce(0) { $0 + $1.unreadCompletionCount }
    }

    func refreshAssistantReadState() {
        for conversation in assistantConversations.conversations where isAssistantConversationVisible(conversation.id) {
            conversation.markNotificationsRead()
        }
    }

    private func isTerminalNotificationFocused(_ id: UUID) -> Bool {
        isCommandWorkspaceFocused(id, windowIsFocused: mainWindows.isFocused)
    }

    @discardableResult
    func selectAssistantNotificationTarget(
        _ id: UUID, windowIsFocused: ((WindowModel) -> Bool)? = nil
    ) -> WindowModel? {
        let isFocused = windowIsFocused ?? mainWindows.isFocused
        let available = windows.values.compactMap(\.value).filter { !$0.isClosed }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        // A hidden Assistant route still belongs to its window. Reuse it before
        // falling back to a window that has no selection for this conversation.
        guard
            let window = available.first(where: { $0.isShowingAssistant(id) && isFocused($0) })
                ?? available.first(where: { $0.isShowingAssistant(id) })
                ?? available.first(where: { $0.assistantLibrary.selectedConversationID == id && isFocused($0) })
                ?? available.first(where: { $0.assistantLibrary.selectedConversationID == id })
                ?? mainWindows.mostRecentWindow ?? available.first
        else { return nil }
        window.isToolbarFindFocused = false
        window.isQuickOpenPresented = false
        if conversation(id) != nil {
            if window.selectedWorkspace != nil {
                window.showAssistant()
                window.openAssistantInSidebar(id)
            } else if !window.isShowingAssistant(id) {
                window.openAssistantFullScreen(id)
            }
        } else {
            window.openAssistantFullScreen()
        }
        return window
    }

    func commandNotificationTarget(_ id: UUID) -> (WindowModel, Workspace, Pane)? {
        for window in windows.values.compactMap(\.value) where !window.isClosed {
            for workspace in window.workspaces {
                if let pane = workspace.panes.first(where: { $0.commandSessionID == id }) {
                    return (window, workspace, pane)
                }
            }
        }
        return nil
    }

    func isCommandWorkspaceFocused(_ id: UUID, windowIsFocused: (WindowModel) -> Bool) -> Bool {
        guard let (window, workspace, _) = commandNotificationTarget(id) else { return false }
        return window.selectedWorkspace === workspace && windowIsFocused(window)
    }

    private func configureCommandMonitor(_ pane: Pane) {
        pane.configureTerminalBell { [weak self, weak pane] in
            guard let self, let pane, self.terminalExperienceSettings.preferences.bellSound,
                let id = pane.commandSessionID, self.commandNotificationTarget(id) != nil,
                self.terminationTask == nil
            else { return }
            self.terminalBellSound()
        }
        guard let monitor = pane.commandMonitor, let id = pane.commandSessionID else { return }
        terminalNotifications.observe(monitor, id: id)
    }

    @discardableResult
    func selectCommandNotificationTarget(_ id: UUID) -> WindowModel? {
        guard let (window, workspace, pane) = commandNotificationTarget(id) else { return nil }
        window.isToolbarFindFocused = false
        window.isQuickOpenPresented = false
        window.select(workspace.id)
        workspace.focusedPaneID = pane.id
        return window
    }

    func openCommandNotification(_ id: UUID) {
        guard let window = selectCommandNotificationTarget(id) else {
            _ = mainWindows.openExisting()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        mainWindows.activate(window)
        if let pane = commandNotificationTarget(id)?.2 {
            pane.sshSession?.requestTerminalFocus()
            pane.telnetSession?.requestTerminalFocus()
            pane.serialSession?.requestTerminalFocus()
        }
    }

    private func configureCommandNotifications(in window: WindowModel) {
        window.configureCommandNotifications = { [weak self] pane in self?.configureCommandMonitor(pane) }
        window.commandFocusChanged = { [weak self, weak window] in
            guard let self, let window, self.mainWindows.isFocused(window) else { return }
            window.selectedWorkspace?.markCommandsRead()
        }
        window.workspaces.flatMap(\.panes).forEach(configureCommandMonitor)
    }

    private func configureConnectionHistory(in window: WindowModel) {
        configureCommandNotifications(in: window)
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
