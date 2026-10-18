import DeviceKit
import Foundation
import Observation
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import UIKit

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileAppModel {
    let terminalRecoveryStore: TerminalRecoveryStore
    private let workspaceStore: MobileWorkspaceStore
    let container: ModelContainer
    let hosts: any HostRepository
    let library: HostLibraryModel
    let tailscale: TailscaleModel
    let credentials: CredentialLibraryModel
    let hostMACResolver: any HostMACAddressResolving
    let keyExportServices: KeyExportServices
    let snippets: SnippetLibraryModel
    let knownHosts: KnownHostsLibraryModel
    let forwardingLibrary: ForwardingLibraryModel
    let forwardings: PortForwardingController
    let sftpEdits: SFTPEditService
    let transfers: SFTPTransferCoordinator
    let notifications = SystemNotifications()
    let notificationSettings: NotificationSettingsModel
    @ObservationIgnored private var sftpNotifications: SFTPNotificationCoordinator?
    @ObservationIgnored private lazy var notificationRouter = MobileNotificationRouter(app: self)
    @ObservationIgnored private var notificationBadge: NotificationBadgeCoordinator?
    @ObservationIgnored private lazy var terminalNotifications = TerminalNotificationCoordinator(
        service: notifications,
        preferences: { [weak self] in self?.notificationSettings.preferences ?? .init() },
        isFocused: { [weak self] in self?.isTerminalNotificationFocused($0) ?? false },
        title: { [weak self] id in self?.workspaces.first { $0.id == id }?.descriptor.title },
        body: CommandNotificationContent.body,
        ringBell: TerminalNotificationPlatform.ringBell)

    @ObservationIgnored private lazy var assistantNotifications = AssistantNotificationCoordinator(
        service: notifications,
        preferences: { [weak self] in self?.notificationSettings.preferences ?? .init() },
        isFocused: { [weak self] in self?.isAssistantNotificationFocused($0) ?? false },
        content: AssistantNotificationContent.make)
    private var workspaceSessions: [MobileWorkspaceSessionModel] = []
    private var paneScenes: [UUID: WeakPaneScene] = [:]
    var workspaces: [MobileWorkspace] { workspaceSessions.flatMap(\.workspaces) }

    private final class WeakPaneScene {
        weak var value: MobileSceneModel?
        init(_ value: MobileSceneModel) { self.value = value }
    }

    func registerPaneScene(_ scene: MobileSceneModel) {
        paneScenes = paneScenes.filter { $0.value.value != nil }
        paneScenes[scene.id] = WeakPaneScene(scene)
    }

    func paneAccess(for source: MobileSceneModel) -> AgentPaneAccess {
        AgentPaneAccess(
            list: { [weak self, weak source] in
                self?.openTerminalPanes(source: source)
                    .filter { $0.workspace.connected && $0.workspace.readViewportText() != nil }
                    .map(\.metadata) ?? []
            },
            read: { [weak self, weak source] id in
                guard let match = self?.openTerminalPanes(source: source).first(where: { $0.metadata.id == id })
                else { return .closed }
                guard match.workspace.connected else { return .notConnected }
                guard let text = match.workspace.readViewportText() else { return .noSurface }
                return .text(match.metadata, text)
            })
    }

    private func openTerminalPanes(source: MobileSceneModel?)
        -> [(metadata: AgentPaneAccess.Pane, workspace: MobileWorkspace)]
    {
        workspaceSessions.flatMap { session in
            session.workspaces.compactMap { workspace in
                guard workspace.descriptor.kind.isSSHTerminal || workspace.descriptor.kind == .telnet else {
                    return nil
                }
                let owner = paneScenes.values.compactMap(\.value).first {
                    $0.workspaceSession === session
                }
                let isActive = owner?.activeWorkspace?.id == workspace.id
                let isCurrent = source?.workspaceSession === session && source?.activeWorkspace?.id == workspace.id
                let metadata = AgentPaneAccess.Pane(
                    id: workspace.id,
                    title: workspace.descriptor.title,
                    hostID: workspace.descriptor.hostID,
                    workspace: workspace.descriptor.title,
                    window: session.id,
                    isActive: isActive,
                    isCurrent: isCurrent
                )
                return (metadata, workspace)
            }
        }
    }
    var error: String?
    let terminalSettings: TerminalSettingsModel
    let terminalExperienceSettings: TerminalExperienceSettingsModel
    let terminalEffects: MobileTerminalEffects
    let screenAwake: MobileScreenAwakeController
    let agentForwardingRouter = MobileAgentForwardingRouter()
    let sshSettings: SSHSettingsModel
    let sftpSettings: SFTPSettingsModel
    let workspaceSettings: WorkspaceSettingsModel
    let connectionHistory: ConnectionHistoryModel
    let devices: DeviceDirectoryModel
    let vaultSync: VaultSyncCoordinator?
    let connectionHistorySync: ConnectionHistorySyncCoordinator?
    let deviceSync: DeviceSyncCoordinator?
    let settingsSync: SettingsSyncCoordinator?
    let metricsSync: MetricsSyncCoordinator?
    let skills: SkillLibraryModel
    let memory: MemoryModel
    let ai: AIConfigurationModel
    let commandGenerator: CommandGeneratorController
    let assistant: MobileAssistantModel
    let metrics: MobileMetricsModel
    let pro: ProAccessController
    let appReview: AppReviewController
    let diagnosis: DiagnosisController
    let logging: any ApplicationLogManaging
    let liveActivities: MobileLiveActivityController
    private var workspaceActivitySessions: [WorkspaceActivityAttributes.Session] {
        workspaceSessions.filter { !$0.isDiscarded }.flatMap { session in
            session.orderedWorkspaceItems.map { item in
                if let workspace = item.workspace { return workspace.activitySession }
                let descriptor = item.descriptor
                let artwork = HostIconCatalog.resolvedArtwork(for: item.host)
                return WorkspaceActivityAttributes.Session(
                    id: descriptor.id, title: descriptor.title, kind: descriptor.kind.rawValue,
                    connected: false, iconAsset: artwork.assetName, iconSystemName: artwork.systemImageName,
                    recovery: .init(
                        sourceWorkspaceID: descriptor.id, hostID: descriptor.hostID, kind: descriptor.kind.rawValue,
                        remoteSession: descriptor.remoteSession.flatMap { try? JSONEncoder().encode($0) }))
            }
        }
    }
    private var hasLoadedWorkspaceSnapshot = false
    @ObservationIgnored private var activeConnectionHistoryIDs: [MobileWorkspace.ID: ConnectionHistoryEntry.ID] = [:]
    private let defaults: UserDefaults?
    private let settingsDefaults: UserDefaults
    private let snippetTimestampFallback: Date
    private let background: any MobileBackgroundTaskManaging
    let workspaceConnectionServices: MobileWorkspaceConnectionServices
    let persistentSessionCloser: RemoteSessionCloseCoordinator
    let recentlyClosedStore = RecentlyClosedStore<RecentlyClosedRecord<MobileWorkspaceDescriptor>>(
        defaults: nil, key: "mobile.recentlyClosed.v2")
    private var orphanedSessionIDs: Set<String> = []
    private var unboundRestoredSessionIDs: Set<String> = []
    private var retiredRestoredSessionIDs: Set<String> = []
    // Disconnect and discard are separate UIKit callbacks. A later explicit discard must still close
    // precisely the workspaces recovered from that window, even if another window already received them.
    private var recoveredWorkspaceIDs: [String: Set<UUID>] = [:]
    private var discardedSessionIDs: Set<String> = []
    var closedWorkspaceStates: [UUID: [MobileWorkspace.ReopenState]] = [:]
    var pendingClosedWindows: Set<UUID> = []
    var createWorkspaceWindow: @MainActor (UUID, @escaping @MainActor () -> Void) -> Void
    var activateWorkspaceSession: @MainActor (String, UUID, @escaping @MainActor () -> Void) -> Void
    var closeWorkspaceSession: @MainActor (String, @escaping @MainActor (any Error) -> Void) -> Void
    var openWorkspaceSessionIDs: @MainActor () -> Set<String>

    let outbox: OutboxRunner
    private var sceneSessionIDs: [UUID: String] = [:]
    private var scenePhases: [UUID: ScenePhase] = [:]

    convenience init(
        hosts: (any HostRepository)? = nil, inMemory: Bool = false, defaults: UserDefaults? = nil,
        background: any MobileBackgroundTaskManaging = MobileBackgroundController(),
        workspaceConnectionServices: MobileWorkspaceConnectionServices = .live,
        appReview: AppReviewController = AppReviewController()
    ) throws {
        try self.init(
            dependencies: MobileAppDependencies(
                hosts: hosts,
                inMemory: inMemory,
                defaults: defaults,
                background: background,
                workspaceConnections: workspaceConnectionServices,
                metrics: inMemory || hosts != nil ? .testing : .live,
                appReview: appReview,
                terminalEffects: inMemory || hosts != nil ? MobileTerminalEffects() : .live
            ))
    }

    init(dependencies: MobileAppDependencies) throws {
        let hosts = dependencies.hosts
        let inMemory = dependencies.inMemory
        let defaults = dependencies.defaults
        terminalEffects = dependencies.terminalEffects
        screenAwake = MobileScreenAwakeController(
            setIdleTimerDisabled: dependencies.terminalEffects.setIdleTimerDisabled)
        let background = dependencies.background
        let workspaceConnectionServices = dependencies.workspaceConnections
        let connectionCoordinator = dependencies.connectionCoordinator
        hostMACResolver = SSHHostMACAddressResolver(coordinator: connectionCoordinator)
        keyExportServices = connectionCoordinator.keyExportServices()
        createWorkspaceWindow = dependencies.createWorkspaceWindow
        activateWorkspaceSession = dependencies.activateWorkspaceSession
        closeWorkspaceSession = dependencies.closeWorkspaceSession
        openWorkspaceSessionIDs = dependencies.openWorkspaceSessionIDs
        self.background = background
        self.workspaceConnectionServices = workspaceConnectionServices
        MobileWorkspaceStore.retire(in: defaults ?? .standard)
        appReview = dependencies.appReview
        diagnosis = dependencies.diagnosis
        logging = dependencies.logging
        let memoryOnly = inMemory || hosts != nil
        terminalRecoveryStore = dependencies.terminalRecoveryStore
        workspaceStore = MobileWorkspaceStore(defaults: memoryOnly ? defaults : defaults ?? .standard)
        let storeURL = URL.applicationSupportDirectory.appending(path: "Termind.store")
        if !memoryOnly {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        container =
            try dependencies.container
            ?? TermindPersistence.makeContainer(inMemory: memoryOnly, url: memoryOnly ? nil : storeURL)
        let vaultContext = ModelContext(container)
        self.hosts = hosts ?? SwiftDataHostRepository(context: vaultContext)
        outbox = OutboxRunner(store: SwiftDataOutboxStore(context: ModelContext(container)))
        self.defaults = inMemory || hosts != nil ? nil : defaults
        snippetTimestampFallback = SnippetTimestamp.fallback(in: self.defaults)
        liveActivities = dependencies.liveActivities ?? MobileLiveActivityController(enabled: !inMemory && hosts == nil)
        pro = dependencies.proAccess ?? (inMemory || hosts != nil ? .unrestrictedForTesting() : .live())
        let persistence = HostPersistence(context: vaultContext)
        _ = try persistence.load()
        let secrets: any SecretStoring =
            inMemory || hosts != nil
            ? InMemorySecretStore()
            : KeychainSecretStore(
                accessGroup: Bundle.main.object(forInfoDictionaryKey: "TermindKeychainAccessGroup") as? String
                    ?? "F6SUNDBBN9.com.akinokaede.termind")
        let settingsDefaults =
            memoryOnly
            ? defaults ?? UserDefaults(suiteName: "termind.tests.\(UUID().uuidString)")!
            : defaults ?? .standard
        self.settingsDefaults = settingsDefaults
        terminalExperienceSettings = TerminalExperienceSettingsModel(defaults: settingsDefaults)
        SettingsKey.migrateSyncPreferences(in: settingsDefaults)
        let settingsPersistence = SettingsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try settingsPersistence.prepare()
        let metricsPersistence = MetricsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try metricsPersistence.prepare()
        let aiSecrets = AISecretStore(
            context: settingsPersistence.context, keychain: secrets, defaults: settingsDefaults)
        terminalSettings = TerminalSettingsModel(persistence: settingsPersistence)
        notificationSettings = NotificationSettingsModel(persistence: settingsPersistence)
        sshSettings = SSHSettingsModel(persistence: settingsPersistence)
        sftpSettings = SFTPSettingsModel(persistence: settingsPersistence)
        workspaceSettings = WorkspaceSettingsModel(persistence: settingsPersistence)
        connectionCoordinator.updateSSHPreferences(sshSettings.preferences)
        let historyPersistence = HistorySyncPersistence(context: vaultContext)
        try historyPersistence.prepare()
        let connectionHistoryRepository = SwiftDataConnectionHistoryRepository(context: vaultContext)
        let deviceDirectoryRepository = SwiftDataDeviceDirectoryRepository(context: vaultContext)
        let currentDeviceID = try VaultSyncJournal(context: vaultContext).state().installationID
        devices = DeviceDirectoryModel(
            repository: deviceDirectoryRepository,
            currentDeviceID: currentDeviceID,
            currentDeviceName: Device.current.safeDescription)
        connectionHistory = ConnectionHistoryModel(
            repository: connectionHistoryRepository,
            sourceDeviceID: currentDeviceID)
        settingsSync =
            memoryOnly
            ? nil
            : SettingsSyncCoordinator(persistence: settingsPersistence, secrets: aiSecrets, defaults: settingsDefaults)
        metricsSync =
            memoryOnly
            ? nil
            : MetricsSyncCoordinator(persistence: metricsPersistence, defaults: settingsDefaults)
        vaultSync = memoryOnly ? nil : VaultSyncCoordinator(context: vaultContext, defaults: settingsDefaults)
        connectionHistorySync =
            memoryOnly
            ? nil : ConnectionHistorySyncCoordinator(persistence: historyPersistence, defaults: settingsDefaults)
        deviceSync =
            memoryOnly ? nil : DeviceSyncCoordinator(persistence: historyPersistence, defaults: settingsDefaults)
        vaultSync?.configureLogging(dependencies.logging)
        connectionHistorySync?.configureLogging(dependencies.logging)
        deviceSync?.configureLogging(dependencies.logging)
        settingsSync?.configureLogging(dependencies.logging)
        metricsSync?.configureLogging(dependencies.logging)
        connectionHistoryRepository.didRecordHistoryChanges = { [weak connectionHistorySync] in
            connectionHistorySync?.noteLocalChanges($0)
        }
        deviceDirectoryRepository.didRecordHistoryChanges = { [weak deviceSync] in
            deviceSync?.noteLocalChanges($0)
        }
        ai = AIConfigurationModel(
            persistence: SyncedAIConfigurationPersistence(settingsPersistence), secrets: secrets,
            permissionDefaults: settingsDefaults, aiSecrets: aiSecrets,
            webSearchPersistence: settingsPersistence,
            mcpSecrets: memoryOnly
                ? InMemoryMCPAuthorizationStore()
                : MCPKeychainCredentialStore(
                    accessGroup: Bundle.main.object(forInfoDictionaryKey: "TermindKeychainAccessGroup") as? String
                        ?? "F6SUNDBBN9.com.akinokaede.termind"))
        commandGenerator = CommandGeneratorController(ai: ai)
        skills = SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(settingsPersistence))
        memory = MemoryModel(
            storage: GRDBMemoryStore(directory: GRDBMemoryStore.defaultDirectory), defaults: settingsDefaults)
        library = HostLibraryModel(
            persistence: persistence, secrets: secrets,
            localDefaults: memoryOnly ? nil : settingsDefaults
        )
        let sessionTerminator = dependencies.persistentSessionTerminator
        persistentSessionCloser = RemoteSessionCloseCoordinator { [library] request in
            try await sessionTerminator.terminate(request, hosts: library)
        }
        let tailscaleDevices = devices
        let tailscaleAccess = pro
        library.hostAccess.entitlement = pro.status
        library.requestHostUpgrade = { [pro] in pro.presentPaywall() }
        library.resolveInitialHostEntitlement = { [pro, weak library] in
            await pro.refresh()
            library?.hostAccess.entitlement = pro.status
        }
        library.wakeOnLAN = WakeOnLANController(
            sender: LANWakeOnLANSender())
        let wakeLogger = dependencies.logging.makeLogger(label: "termind.wake-on-lan")
        library.wakeOnLAN?.reportAutomaticFailure = { _ in wakeLogger.warning("wake.automatic.failed") }
        tailscale = TailscaleModel(
            library: library, store: SwiftDataTailscaleLocalStore(context: ModelContext(container)),
            factory: { profileID, hostname, controlURL, authKey in
                guard !memoryOnly else { throw TailscaleConfigurationError.unavailable }
                return try await LibTailscaleNodeSession.factory(profileID, hostname, controlURL, authKey)
            },
            profileStorage: memoryOnly ? .disabled : LibTailscaleNodeSession.profileStorage,
            hostname: { tailscaleDevices.currentDeviceName }, hasAccess: { tailscaleAccess.canUse(.tailscale) }
        )
        let forwardingRouter = agentForwardingRouter
        connectionCoordinator.updateAgentForwarding(
            VaultSSHAgent.factory(
                library: library, interactionContext: { forwardingRouter.context(for: $0) }))
        if !memoryOnly { try? library.migrateCustomPasswordsToICloud() }
        vaultSync?.beforeSend = { [weak library] in try library?.migrateCustomPasswordsToICloud() }
        metrics = MobileMetricsModel(
            preferences: metricsPersistence, hosts: library, services: dependencies.metrics)
        let speechAudio = IOSSpeechAudioInput()
        let speech = SpeechTranscriptionCoordinator(
            service: AppleSpeechTranscriptionService(audioInput: speechAudio)
        )
        speechAudio.onInterruption = { [weak speech] in speech?.cancelAll() }
        let sftpPreferences = MultiConnectionPolicy(
            allowsMultipleConnections: pro.canUse(.sftpMultiConnection)
        ).sftpPreferences(sftpSettings.preferences)
        let sftpConcurrencyScheduler = SFTPConcurrencyScheduler(preferences: sftpPreferences)
        assistant = MobileAssistantModel(
            configuration: ai,
            repository: MemoryIndexedAgentRepository(
                base: SwiftDataAgentRunRepository(context: ModelContext(container)), memory: memory),
            memory: memory,
            modelSelectionStore: SwiftDataAssistantModelSelectionStore(context: ModelContext(container)),
            chatCollaborationStore: SwiftDataAssistantChatCollaborationStore(
                context: ModelContext(container)),
            hostServices: AgentHostServices.live(
                store: library,
                coordinator: connectionCoordinator,
                sftpConcurrencyScheduler: sftpConcurrencyScheduler),
            metrics: metrics.core, skills: skills,
            authorize: { true },
            speech: speech,
            attachmentLoader: .live,
            logger: logging.makeLogger(label: "termind.agent")
        )
        credentials = CredentialLibraryModel(library: library)
        snippets = SnippetLibraryModel(library: library)
        knownHosts = KnownHostsLibraryModel(library: library)
        forwardingLibrary = ForwardingLibraryModel(library: library)
        forwardings = dependencies.makeForwardings(library)
        transfers = SFTPTransferCoordinator(
            store: library, clientFactory: { connectionCoordinator.makeSFTPClient() },
            globalLimit: sftpPreferences.globalLimit,
            perHostLimit: sftpPreferences.perHostLimit,
            strategy: sftpPreferences.strategy,
            concurrencyScheduler: sftpConcurrencyScheduler)
        sftpEdits = SFTPEditService(transfers: transfers, host: { [weak library] in library?.host($0) })
        library.willDeleteHost = { [weak sftpEdits, weak forwardings] hostID, _ in
            sftpEdits?.invalidate(hostID: hostID)
            forwardings?.hostConfigurationChanged(hostID)
        }
        library.willDeletePortForwardings = { [weak forwardings] ids in forwardings?.stop(ids) }
        library.didChangeHostConnection = { [weak forwardings, weak self] hostID in
            forwardings?.hostConfigurationChanged(hostID)
            self?.disconnectWorkspaces(for: hostID, protocol: .ssh)
        }
        library.didChangeTelnetConnection = { [weak self] hostID in
            self?.disconnectWorkspaces(for: hostID, protocol: .telnet)
        }
        let visibleHostIDs = Set(try self.hosts.snapshot().value.hosts.map(\.id))
        for host in library.hosts where !visibleHostIDs.contains(host.id) { library.projectHostDeletion(host.id) }
        outbox.registerHostDeletionHandlers(
            repository: self.hosts,
            closeWorkspaces: { [weak self] payload in
                guard let self else { return }
                closeWorkspaces(for: payload.hostID)
                connectionHistory.clear(for: payload.hostID)
                library.projectHostDeletion(payload.hostID)
            },
            cancelTransfers: { [weak self] payload in
                guard let self else { return }
                sftpEdits.invalidate(hostID: payload.hostID)
                transfers.cancelAll(for: payload.hostID)
            },
            stopForwardings: { [weak forwardings] payload in
                forwardings?.hostConfigurationChanged(payload.hostID)
                forwardings?.remove(payload.forwardingRuleIDs)
            }
        )
        library.didRecordVaultChanges = { [weak vaultSync] in vaultSync?.noteLocalChanges($0) }
        if let repository = self.hosts as? SwiftDataHostRepository {
            repository.didRecordHistoryChanges = { [weak connectionHistorySync] in
                connectionHistorySync?.noteLocalChanges($0)
            }
            repository.didRecordVaultChanges = { [weak vaultSync] in vaultSync?.noteLocalChanges($0) }
        }
        connectionHistorySync?.didApplyRemote = { [weak self] _ in self?.connectionHistory.reload() }
        deviceSync?.didApplyRemote = { [weak self] _ in self?.devices.reload() }
        vaultSync?.didApplyRemote = { [weak self] in self?.applyRemoteVault($0, keys: $1) }
        sftpSettings.didChange = { [weak self] _ in
            self?.reconcileConnectionPreferences()
        }
        library.didDeleteTailscaleGroups = { [weak self] groups, hostIDs in
            guard let self else { return }
            self.metrics.core.removeTailscaleGroups(groups)
            for id in hostIDs {
                self.closeWorkspaces(for: id)
                self.sftpEdits.invalidate(hostID: id)
                self.transfers.cancelAll(for: id)
                self.metrics.core.remove(id)
            }
        }
        tailscale.start()
        pro.accessDidChange = { [weak self] in
            if let self { self.library.hostAccess.entitlement = self.pro.status }
            self?.reconcileSync()
            self?.tailscale.reconcile()
            self?.metrics.core.reconcile()
            self?.reconcileConnectionPreferences()
        }
        sshSettings.didChange = { preferences in
            connectionCoordinator.updateSSHPreferences(preferences)
        }
        assistant.observeNotifications = { [weak self] in self?.assistantNotifications.observe($0) }
        sftpNotifications = SFTPNotificationCoordinator(
            service: notifications, initialTransfers: library.sftpTransfers,
            preferences: { [weak self] in self?.notificationSettings.preferences ?? .init() },
            isFocused: { [weak self] in self?.scenePhases.values.contains { $0 != .background } ?? false },
            content: SFTPNotificationContent.make)
        library.sftpTransferStateDidChange = { [weak self] in self?.sftpNotifications?.receive($0) }
        library.sftpTransfersDidRemove = { [weak self] in self?.sftpNotifications?.forgetFinishedTransfers($0) }
        notifications.onOpen = { [weak self] target in self?.notificationRouter.open(target) }
        notificationBadge = NotificationBadgeCoordinator(service: notifications) { [weak self] in
            guard let self, self.notificationSettings.preferences.isEnabled else { return 0 }
            return self.unreadNotificationCount
        }
        ai.didChange = { [weak assistant] in assistant?.repairUnavailableModels() }
        settingsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.ai.applyRemoteSnapshot(snapshot.configuration, webSearch: snapshot.webSearch)
            self?.terminalSettings.applyRemoteSnapshot(snapshot.terminal)
            self?.terminalSettings.applyRemoteThemes(snapshot.terminalThemes)
            self?.sshSettings.applyRemoteSnapshot(snapshot.ssh)
            self?.sftpSettings.applyRemoteSnapshot(snapshot.sftp)
            self?.workspaceSettings.applyRemoteSnapshot(snapshot.workspace)
            self?.notificationSettings.applyRemoteSnapshot(snapshot.notifications)
            self?.skills.applyRemoteSnapshot(snapshot.skills)
        }
        metricsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.metrics.core.applyRemoteSnapshot(snapshot)
        }
        do {
            let snapshot = try workspaceStore.load()
            workspaceSessions = snapshot.sessions.sorted { $0.key < $1.key }.map {
                MobileWorkspaceSessionModel(id: $0.key, app: self, descriptors: $0.value)
            }
            unboundRestoredSessionIDs = Set(snapshot.sessions.keys)
            hasLoadedWorkspaceSnapshot = true
            liveActivities.restore(workspaceActivitySessions)
        } catch {
            self.error = error.localizedDescription
        }
        observeHostArtwork()
    }

    private var workspaceSnapshot: MobileWorkspaceStore.Snapshot {
        let sessions = workspaceSessions.filter { !$0.isDiscarded }.map { ($0.id, $0.restorableDescriptors) }
        return .init(sessions: Dictionary(uniqueKeysWithValues: sessions))
    }

    func persistWorkspaceDescriptors() {
        do {
            try workspaceStore.save(workspaceSnapshot)
        } catch {
            self.error = error.localizedDescription
        }
        updateWorkspaceActivity()
    }

    private func updateWorkspaceActivity() {
        // A failed read is not an authoritative empty list.
        guard hasLoadedWorkspaceSnapshot else { return }
        liveActivities.update(workspaceActivitySessions)
    }

    private func reconcileConnectionPreferences() {
        let policy = MultiConnectionPolicy(allowsMultipleConnections: pro.canUse(.sftpMultiConnection))
        transfers.updatePreferences(policy.sftpPreferences(sftpSettings.preferences))
    }

    var newVaultKeyStorage: KeyStorage {
        NewVaultCredentialStorage.keyStorage(
            defaults: settingsDefaults,
            canUseVaultSync: pro.canUse(.vaultSync))
    }

    var newVaultPasswordStorage: PasswordStorage {
        NewVaultCredentialStorage.passwordStorage(
            defaults: settingsDefaults,
            canUseVaultSync: pro.canUse(.vaultSync))
    }

    private func disconnectWorkspaces(
        for hostID: Host.ID, protocol connectionProtocol: HostTerminalProtocol
    ) {
        for workspace in workspaces where workspace.descriptor.hostID == hostID {
            let matches =
                switch (connectionProtocol, workspace.descriptor.kind) {
                case (.ssh, .ssh), (.ssh, .mosh), (.ssh, .eternalTerminal), (.ssh, .sftp), (.telnet, .telnet): true
                default: false
                }
            if matches { workspace.disconnect() }
        }
    }

    private func closeWorkspaces(for hostID: UUID) {
        forgetClosedWorkspaces(for: hostID)
        for session in workspaceSessions {
            for item in session.orderedWorkspaceItems where item.descriptor.hostID == hostID {
                session.close(item.id, rememberForReopen: false)
            }
        }
    }

    @discardableResult
    func deleteHost(_ id: UUID) -> Bool {
        guard library.host(id)?.isTailscaleManaged != true else { return false }
        do {
            assistant.disconnectHost(id)
            closeWorkspaces(for: id)
            sftpEdits.invalidate(hostID: id)
            transfers.cancelAll(for: id)
            forwardings.hostConfigurationChanged(id)
            forwardings.remove(library.portForwardings(for: id).map(\.id))
            metrics.remove(id)
            try hosts.requestHostDeletion(id)
            library.projectHostDeletion(id)
            outbox.start()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteHostGroup(_ id: HostGroup.ID, keepHosts: Bool) {
        if !keepHosts {
            let hosts = library.hosts(inTreeOf: id).filter { !$0.isTailscaleManaged }
            guard hosts.allSatisfy({ deleteHost($0.id) }) else { return }
        }
        library.deleteGroupProjection(id)
        if let storageError = library.storageError { error = storageError }
    }

    func duplicateHost(_ host: Host) async {
        do {
            let saved = try await library.duplicateHost(
                host, name: String(localized: AppStrings.Vault.duplicatedHostName(host.name)))
            if !saved { error = library.storageError }
        } catch is CancellationError {
        } catch {
            self.error = HostAccessError.presentationDescription(of: error)
        }
    }

    func lastConnectedAt(for hostID: Host.ID) -> Date? {
        connectionHistory.mostRecentDate(for: hostID)
    }

    func snippetModifiedAt(for snippetID: Snippet.ID) -> Date {
        SnippetTimestamp.resolve(
            modifiedAt: snippets.modifiedAt(for: snippetID), fallback: snippetTimestampFallback)
    }

    func disconnectWorkspaceScene(_ sessionID: String) {
        guard !discardedSessionIDs.contains(sessionID) else { return }
        for id in Array(sceneSessionIDs.keys) where sceneSessionIDs[id] == sessionID {
            sceneChanged(id, phase: .background)
            removeScene(id)
        }
        // A disconnected UIScene may still have a restorable UISceneSession. Only a native
        // openSessions reconciliation can establish that its window has actually disappeared.
    }

    func reconcileWorkspaceSessions(
        openSessionIDs: Set<String>, activeSessionID: String?, supportsMultipleScenes: Bool = true
    ) {
        // On single-window devices UIKit can still report archived sessions from a previous launch.
        // Their workspaces belong in the current list, not in an unreachable Live Activity-only owner.
        let ownerIDs =
            supportsMultipleScenes ? openSessionIDs : Set([activeSessionID].compactMap { $0 })
        orphanedSessionIDs = Set(workspaceSessions.map(\.id))
            .subtracting(ownerIDs.subtracting(retiredRestoredSessionIDs)).subtracting(discardedSessionIDs)
        let target = activeSessionID.flatMap { id in workspaceSessions.first { $0.id == id } }
        if let target, openSessionIDs.contains(target.id) { recoverOrphanedWorkspaces(into: target) }
    }

    private func recoverOrphanedWorkspaces(into target: MobileWorkspaceSessionModel) {
        orphanedSessionIDs.remove(target.id)
        guard !target.isDiscarded else { return }
        let sources = workspaceSessions.filter { orphanedSessionIDs.contains($0.id) }
        guard !sources.isEmpty else { return }
        let recoveries = sources.map { ($0, $0.recovery) }
        var snapshot = workspaceSnapshot
        for (source, recovery) in recoveries {
            snapshot.sessions[source.id] = []
            snapshot.sessions[target.id, default: []].append(contentsOf: recovery.descriptors)
        }
        // Commit the complete handoff before releasing any source, including dormant records.
        do {
            try workspaceStore.save(snapshot)
        } catch {
            self.error = String(localized: AppStrings.Workspace.workspaceChangesCouldNotBeSavedForTheNextLaunch)
            return
        }
        for (source, recovery) in recoveries {
            // Only a window used in this process can later explicitly close its transferred work.
            if !unboundRestoredSessionIDs.contains(source.id) {
                recoveredWorkspaceIDs[source.id, default: []].formUnion(recovery.order)
            }
            source.releaseForRecovery()
            target.acceptRecovery(recovery)
            orphanedSessionIDs.remove(source.id)
        }
        updateWorkspaceActivity()
    }

    func sceneChanged(_ id: UUID, phase: ScenePhase, workspaceSessionID: String? = nil) {
        if let workspaceSessionID { sceneSessionIDs[id] = workspaceSessionID }
        let wasBackground = allScenesAreBackgrounded
        scenePhases[id] = phase
        if phase != .active { screenAwake.update(sceneID: id, wantsAwake: false) }
        refreshCommandFocus()
        if phase == .active {
            Task { [weak self] in
                await Task.yield()
                guard let self, self.scenePhases[id] == .active else { return }
                self.notificationRouter.resume()
            }
        }
        let isBackground = allScenesAreBackgrounded
        if isBackground && !wasBackground {
            enterBackground()
        } else if phase == .active {
            devices.updateCurrentDeviceName(Device.current.safeDescription)
            sftpEdits.setMonitoring(true)
            memory.resume()
            Task { await sftpEdits.recheck() }
            Task { [weak self] in await self?.pro.refresh() }
            background.finish()
            for workspace in workspaces { workspace.resumeAfterBackground() }
            reconcileSync()
            outbox.start()
            updateWorkspaceActivity()
            metrics.start()
        }
    }

    func reconcileSync() {
        let foreground = scenePhases.values.contains(.active)
        if foreground && pro.canUse(.vaultSync) {
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

    func setSyncEnabled(_ value: Bool, key: String) {
        guard !value || pro.require(.vaultSync) else { return }
        defaults?.set(value, forKey: key)
        if key == SettingsKey.historySyncEnabled { connectionHistorySync?.setEnabled(value) }
        if value && key == SettingsKey.iCloudSyncEnabled {
            do { try library.migrateCustomPasswordsToICloud() } catch { self.error = error.localizedDescription }
        }
        reconcileSync()
    }

    func applyRemoteVault(_ snapshot: VaultSnapshot, keys: Set<VaultRecordKey>) {
        let retainedHostIDs = Set(snapshot.hosts.map(\.id))
        for key in keys where key.kind == .host && !retainedHostIDs.contains(key.id) {
            metrics.core.remove(key.id)
        }
        let plan = VaultRemoteChangePlan.make(
            currentHosts: library.hosts,
            snapshot: snapshot,
            changedKeys: keys
        )
        for change in plan.hosts {
            if change.routeChanged {
                sftpEdits.invalidate(hostID: change.id)
                if !change.isRemoved {
                    for workspace in workspaces.filter({ $0.descriptor.hostID == change.id }) { workspace.disconnect() }
                }
                transfers.cancelAll(for: change.id)
                forwardings.stop(library.portForwardings(for: change.id).map(\.id))
            }
            if change.isRemoved {
                closeWorkspaces(for: change.id)
                connectionHistory.clear(for: change.id)
                metrics.remove(change.id)
            }
        }
        forwardings.stop(plan.forwardingRuleIDs)
        library.replacePersistedSnapshot(snapshot)
        forwardings.reconcileConfiguration()
        updateWorkspaceActivity()
    }

    func removeScene(_ id: UUID) {
        screenAwake.update(sceneID: id, wantsAwake: false)
        let wasBackground = allScenesAreBackgrounded
        scenePhases[id] = nil
        sceneSessionIDs[id] = nil
        paneScenes[id] = nil
        if allScenesAreBackgrounded && !wasBackground { enterBackground() }
        reconcileSync()
    }

    private var allScenesAreBackgrounded: Bool {
        !scenePhases.isEmpty && scenePhases.values.allSatisfy { $0 == .background }
    }

    private func enterBackground() {
        sftpEdits.setMonitoring(false)
        memory.suspend()
        vaultSync?.pause()
        connectionHistorySync?.pause()
        deviceSync?.pause()
        metricsSync?.pause()
        settingsSync?.pause()
        metrics.pause()
        outbox.stop()
        assistant.suspendRecording()
        background.begin { [weak self] in
            guard let self else { return }
            persistentSessionCloser.cancelAll()
            for workspace in workspaces { workspace.suspendForBackgroundExpiration() }
            forwardings.stopAll()
            transfers.pauseAll()
            assistant.expireBackground()
        }
        for workspace in workspaces { workspace.suspendResumableTransport() }
        updateWorkspaceActivity()
    }

    func focusWorkspaceActivity(_ id: UUID) {
        guard hasLoadedWorkspaceSnapshot else { return }
        liveActivities.focus(id, in: workspaceActivitySessions)
    }

    func workspaceSession(for id: String) -> MobileWorkspaceSessionModel {
        unboundRestoredSessionIDs.remove(id)
        retiredRestoredSessionIDs.remove(id)
        if let session = workspaceSessions.first(where: { $0.id == id }) { return session }
        let session = MobileWorkspaceSessionModel(id: id, app: self, descriptors: [])
        workspaceSessions.append(session)
        if discardedSessionIDs.contains(id) { session.discard() }
        return session
    }

    func workspaceOwner(_ workspaceID: UUID) -> String? {
        if let session = workspaceSessions.first(where: { $0.orderedWorkspaceItems.contains { $0.id == workspaceID } })
        {
            return session.id
        }
        return nil
    }

    func discardWorkspaceSessions(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        // UIKit may discard last process's windows before their records find a new native owner.
        let restored = ids.intersection(unboundRestoredSessionIDs)
        retiredRestoredSessionIDs.formUnion(restored)
        orphanedSessionIDs.formUnion(restored)
        let ids = ids.subtracting(restored)
        guard !ids.isEmpty else { return }
        // Native dismissal detaches clients; only explicit workspace closure ends owned remote work.
        discardedSessionIDs.formUnion(ids)
        orphanedSessionIDs.subtract(ids)
        for id in Array(sceneSessionIDs.keys) where ids.contains(sceneSessionIDs[id] ?? "") { removeScene(id) }
        // A native discard can arrive after reconciliation moved the disappearing window's workspaces.
        for id in ids {
            if let recovered = recoveredWorkspaceIDs[id], !recovered.isEmpty {
                let states = workspaceSessions.flatMap(\.orderedWorkspaceItems)
                    .filter { recovered.contains($0.id) }
                    .map { $0.workspace?.reopenState ?? .init(descriptor: $0.descriptor) }
                rememberClosedWorkspaces(states, isWindow: true)

            }
        }
        let recoveredIDs = ids.reduce(into: Set<UUID>()) { $0.formUnion(recoveredWorkspaceIDs[$1] ?? []) }
        for session in workspaceSessions {
            for workspaceID in recoveredIDs { session.close(workspaceID, rememberForReopen: false, authorized: true) }
        }
        for id in ids { recoveredWorkspaceIDs[id] = nil }
        for session in workspaceSessions where ids.contains(session.id) { session.discard() }
        workspaceSessions.removeAll { ids.contains($0.id) }
        persistWorkspaceDescriptors()
    }

    func containsWorkspace(_ id: UUID) -> Bool {
        workspaceSessions.contains { session in session.orderedWorkspaceItems.contains { $0.id == id } }
    }

    func isAssistantNotificationFocused(_ id: UUID) -> Bool {
        paneScenes.values.compactMap(\.value).contains { $0.isShowingAssistant(id) }
    }

    var unreadAssistantNotificationCount: Int {
        assistant.store.conversations.filter { !$0.isArchived }.reduce(0) { $0 + $1.unreadNotificationCount }
    }

    var unreadNotificationCount: Int {
        unreadAssistantNotificationCount + workspaceSessions.reduce(0) { $0 + $1.unreadCompletionCount }
    }

    func refreshAssistantReadState() {
        for conversation in assistant.store.conversations where isAssistantNotificationFocused(conversation.id) {
            conversation.markNotificationsRead()
        }
    }

    func clearNotificationBadge() {
        notificationBadge?.stop()
        sftpNotifications?.stop()
        assistantNotifications.stop()
        terminalNotifications.stop()
        notificationRouter.stop()
    }

    private func isTerminalNotificationFocused(_ id: UUID) -> Bool { isCommandWorkspaceFocused(id) }

    func isNotificationSceneActive(_ scene: MobileSceneModel) -> Bool { scenePhases[scene.id] == .active }

    var hasActiveNotificationScene: Bool { scenePhases.values.contains(.active) }

    private var notificationScenes: [MobileSceneModel] {
        paneScenes.values.compactMap(\.value).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func transferNotificationTarget() -> MobileSceneModel? {
        let available = notificationScenes
        return available.first(where: isNotificationSceneActive) ?? available.first
    }

    func assistantNotificationTarget(_ id: UUID) -> MobileSceneModel? {
        let available = notificationScenes
        return available.first(where: { isNotificationSceneActive($0) && $0.isShowingAssistant(id) })
            ?? available.first(where: { $0.isShowingAssistant(id) })
            ?? available.first(where: {
                isNotificationSceneActive($0) && $0.assistant.library.selectedConversationID == id
            })
            ?? available.first(where: { $0.assistant.library.selectedConversationID == id })
            ?? available.first(where: isNotificationSceneActive) ?? available.first
    }

    func isCommandWorkspaceFocused(_ id: UUID) -> Bool {
        paneScenes.values.compactMap(\.value).contains {
            scenePhases[$0.id] == .active && $0.activeWorkspace?.id == id
        }
    }

    func refreshCommandFocus() {
        for scene in paneScenes.values.compactMap(\.value) where scenePhases[scene.id] == .active {
            if let workspace = scene.activeWorkspace { scene.workspaceSession.markRead(workspace.id) }
        }
    }

    func commandNotificationTarget(in sessionID: String) -> MobileSceneModel? {
        let available = notificationScenes.filter { $0.workspaceSession.id == sessionID }
        return available.first(where: isNotificationSceneActive) ?? available.first
    }

    func closePersistentSessions(_ targets: [MobileWorkspaceItem]) -> Set<UUID> {
        let requests = targets.compactMap { item -> (UUID, RemoteSessionCloseRequest)? in
            if let workspace = item.workspace {
                return workspace.takePersistentSessionCloseRequest().map { (item.id, $0) }
            }
            guard let reference = item.descriptor.remoteSession, reference.isManaged,
                let host = item.host, host.id == reference.hostID,
                "\(host.host):\(host.sshPort)" == reference.endpoint,
                let snapshot = try? library.resumableControlSnapshot(for: host, username: reference.username)
            else { return nil }
            return (item.id, RemoteSessionCloseRequest(reference: reference, snapshot: snapshot))
        }.sorted { $0.1.connection != nil && $1.1.connection == nil }
        return Set(requests.compactMap { persistentSessionCloser.enqueue($0.1) ? $0.0 : nil })
    }

    func workspaceWillOpen(_ workspace: MobileWorkspace, close: @escaping (UUID) -> Void) {
        workspace.configureTerminalBell { [weak self, weak workspace] in
            guard let self, let workspace, self.hasActiveNotificationScene,
                self.containsWorkspace(workspace.id)
            else { return }
            let preferences = self.terminalExperienceSettings.preferences
            if preferences.bellVibration { self.terminalEffects.vibration() }
            if preferences.bellSound { self.terminalEffects.sound() }
        }
        terminalNotifications.observe(workspace.commandMonitor, id: workspace.id)

        observeActivityState(of: workspace)
        workspace.didRequestClose = close
        startConnectionHistory(for: workspace)
    }

    private func observeHostArtwork() {
        withObservationTracking {
            _ = library.hosts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for workspace in self.workspaces { workspace.refreshHostArtwork() }
                self.updateWorkspaceActivity()
                self.observeHostArtwork()
            }
        }
    }

    func workspacesDidOpen() {
        guard hasLoadedWorkspaceSnapshot else { return }
        liveActivities.start(workspaceActivitySessions)
    }

    func workspaceDidClose(_ id: UUID) {
        Task { [terminalRecoveryStore] in try? await terminalRecoveryStore.discard(id) }
        endConnectionHistory(for: id)
    }

    private func startConnectionHistory(for workspace: MobileWorkspace) {
        guard activeConnectionHistoryIDs[workspace.id] == nil,
            library.host(workspace.descriptor.hostID) != nil,
            let entry = connectionHistory.record(
                kind: workspace.descriptor.kind, for: workspace.descriptor.hostID)
        else { return }
        activeConnectionHistoryIDs[workspace.id] = entry.id
    }

    private func endConnectionHistory(for workspaceID: MobileWorkspace.ID) {
        guard let entryID = activeConnectionHistoryIDs.removeValue(forKey: workspaceID) else { return }
        connectionHistory.end(entryID)
    }

    private func observeActivityState(of workspace: MobileWorkspace) {
        workspace.didChangeState = { [weak self] session in
            guard let self, containsWorkspace(session.id) else { return }
            persistWorkspaceDescriptors()
        }
    }
}
