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

enum MobileSnippetTimestamp {
    static let fallbackKey = "mobile.snippets.baselineModifiedAtFallback.v1"

    static func fallback(in defaults: UserDefaults?) -> Date {
        if let existing = defaults?.object(forKey: fallbackKey) as? Date { return existing }
        let date = Date()
        defaults?.set(date, forKey: fallbackKey)
        return date
    }

    static func resolve(modifiedAt: Date?, fallback: Date) -> Date {
        guard let modifiedAt, modifiedAt > VaultVersion.baselineDate else { return fallback }
        return modifiedAt
    }
}

@MainActor
@Observable
final class MobileAppModel {
    let container: ModelContainer
    let hosts: any HostRepository
    let library: HostLibraryModel
    let credentials: CredentialLibraryModel
    let snippets: SnippetLibraryModel
    let knownHosts: KnownHostsLibraryModel
    let forwardingLibrary: ForwardingLibraryModel
    let forwardings: PortForwardingController
    let sftpEdits: SFTPEditService
    let transfers: SFTPTransferCoordinator
    private var workspaceSessions: [MobileWorkspaceSessionModel] = []
    var workspaces: [MobileWorkspace] { workspaceSessions.flatMap(\.workspaces) }
    var error: String?
    let terminalSettings: TerminalSettingsModel
    let sshSettings: SSHSettingsModel
    let sftpSettings: SFTPSettingsModel
    let workspaceSettings: WorkspaceSettingsModel
    let commandHistory: CommandHistoryModel
    let sftpHistory: SFTPHistoryModel
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
    let logging: any ApplicationLogManaging
    let liveActivities: MobileLiveActivityController
    @ObservationIgnored private var workspaceActivitySessions: [WorkspaceActivityAttributes.Session] = []
    @ObservationIgnored private var activeConnectionHistoryIDs: [MobileWorkspace.ID: ConnectionHistoryEntry.ID] = [:]
    private let defaults: UserDefaults?
    private let settingsDefaults: UserDefaults
    private let snippetTimestampFallback: Date
    private let background: any MobileBackgroundTaskManaging
    let workspaceConnectionServices: MobileWorkspaceConnectionServices
    private let workspaceStore: MobileWorkspaceStore
    private var workspaceSnapshot = MobileWorkspaceStore.Snapshot()
    private var hasBoundWorkspaceSession = false
    private var orphanedSessionIDs: Set<String> = []
    // Disconnect and discard are separate UIKit callbacks. A later explicit discard must still close
    // precisely the workspaces recovered from that window, even if another window already received them.
    private var recoveredWorkspaceIDs: [String: Set<UUID>] = [:]
    private var discardedSessionIDs: Set<String> = []
    var activateWorkspaceSession: @MainActor (String, UUID, @escaping @MainActor () -> Void) -> Void

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
                appReview: appReview
            ))
    }

    init(dependencies: MobileAppDependencies) throws {
        let hosts = dependencies.hosts
        let inMemory = dependencies.inMemory
        let defaults = dependencies.defaults
        let background = dependencies.background
        let workspaceConnectionServices = dependencies.workspaceConnections
        let connectionCoordinator = dependencies.connectionCoordinator
        activateWorkspaceSession = dependencies.activateWorkspaceSession
        self.background = background
        self.workspaceConnectionServices = workspaceConnectionServices
        workspaceStore =
            dependencies.workspaceStore
            ?? MobileWorkspaceStore(defaults: inMemory || hosts != nil ? nil : defaults)
        appReview = dependencies.appReview
        logging = dependencies.logging
        let memoryOnly = inMemory || hosts != nil
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
        snippetTimestampFallback = MobileSnippetTimestamp.fallback(in: self.defaults)
        liveActivities = dependencies.liveActivities ?? MobileLiveActivityController(enabled: !inMemory && hosts == nil)
        pro = inMemory || hosts != nil ? .unrestrictedForTesting() : .live()
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
        SettingsKey.migrateSyncPreferences(in: settingsDefaults)
        let settingsPersistence = SettingsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try settingsPersistence.prepare()
        let metricsPersistence = MetricsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try metricsPersistence.prepare()
        let aiSecrets = AISecretStore(
            context: settingsPersistence.context, keychain: secrets, defaults: settingsDefaults)
        terminalSettings = TerminalSettingsModel(persistence: settingsPersistence)
        sshSettings = SSHSettingsModel(persistence: settingsPersistence)
        sftpSettings = SFTPSettingsModel(persistence: settingsPersistence)
        workspaceSettings = WorkspaceSettingsModel(persistence: settingsPersistence)
        connectionCoordinator.updateSSHPreferences(sshSettings.preferences)
        commandHistory = CommandHistoryModel(
            repository: SwiftDataCommandHistoryRepository(context: ModelContext(container)))
        sftpHistory = SFTPHistoryModel(
            repository: SwiftDataSFTPHistoryRepository(context: ModelContext(container)))
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
            webSearchPersistence: settingsPersistence)
        commandGenerator = CommandGeneratorController(ai: ai)
        skills = SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(settingsPersistence))
        memory = MemoryModel(
            storage: GRDBMemoryStore(directory: GRDBMemoryStore.defaultDirectory), defaults: settingsDefaults)
        library = HostLibraryModel(
            persistence: persistence, secrets: secrets,
            localDefaults: memoryOnly ? nil : settingsDefaults
        )
        if !memoryOnly { try? library.migrateCustomPasswordsToICloud() }
        vaultSync?.beforeSend = { [weak library] in try library?.migrateCustomPasswordsToICloud() }
        metrics = MobileMetricsModel(
            preferences: metricsPersistence, hosts: library, services: dependencies.metrics)
        let speechAudio = IOSSpeechAudioInput()
        let speech = SpeechTranscriptionCoordinator(
            service: AppleSpeechTranscriptionService(audioInput: speechAudio)
        )
        speechAudio.onInterruption = { [weak speech] in speech?.cancelAll() }
        let sftpConcurrencyScheduler = SFTPConcurrencyScheduler(preferences: sftpSettings.preferences)
        assistant = MobileAssistantModel(
            configuration: ai,
            repository: MemoryIndexedAgentRepository(
                base: SwiftDataAgentRunRepository(context: ModelContext(container)), memory: memory),
            memory: memory,
            modelSelectionStore: SwiftDataAssistantModelSelectionStore(context: ModelContext(container)),
            hostServices: AgentHostServices.live(
                store: library,
                coordinator: connectionCoordinator,
                sftpConcurrencyScheduler: sftpConcurrencyScheduler),
            metrics: metrics.core, skills: skills,
            authorize: { [pro] in pro.require(.assistant) },
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
            globalLimit: sftpSettings.preferences.globalLimit,
            perHostLimit: sftpSettings.preferences.perHostLimit,
            strategy: sftpSettings.preferences.strategy,
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
                commandHistory.clear(for: payload.hostID)
                sftpHistory.clear(for: payload.hostID)
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
        sftpSettings.didChange = { [weak transfers] preferences in
            transfers?.updatePreferences(preferences)
        }
        sshSettings.didChange = { preferences in
            connectionCoordinator.updateSSHPreferences(preferences)
        }
        ai.didChange = { [weak assistant] in assistant?.repairUnavailableModels() }
        settingsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.ai.applyRemoteSnapshot(snapshot.configuration, webSearch: snapshot.webSearch)
            self?.terminalSettings.applyRemoteSnapshot(snapshot.terminal)
            self?.sshSettings.applyRemoteSnapshot(snapshot.ssh)
            self?.sftpSettings.applyRemoteSnapshot(snapshot.sftp)
            self?.workspaceSettings.applyRemoteSnapshot(snapshot.workspace)
            self?.skills.applyRemoteSnapshot(snapshot.skills)
        }
        metricsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.metrics.core.applyRemoteSnapshot(snapshot)
        }
        loadRecentWorkspaces()
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
                case (.ssh, .ssh), (.ssh, .sftp), (.telnet, .telnet): true
                default: false
                }
            if matches { workspace.disconnect() }
        }
    }

    private func closeWorkspaces(for hostID: UUID) {
        for session in workspaceSessions {
            for item in session.orderedWorkspaceItems where item.descriptor.hostID == hostID {
                session.close(item.id)
            }
        }
        workspaceSnapshot.unassigned.removeAll { $0.hostID == hostID }
        for id in workspaceSnapshot.sessions.keys {
            workspaceSnapshot.sessions[id]?.removeAll { $0.hostID == hostID }
        }
        persistWorkspaceSnapshot()
    }

    @discardableResult
    func deleteHost(_ id: UUID) -> Bool {
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
            let hosts = library.hosts(inTreeOf: id)
            guard hosts.allSatisfy({ deleteHost($0.id) }) else { return }
        }
        library.deleteGroupProjection(id)
        if let storageError = library.storageError { error = storageError }
    }

    func duplicateHost(_ host: Host) {
        var copy = host
        if host.identityID.flatMap(library.identity)?.isHostCustom == true { copy.identityID = nil }
        if host.telnetIdentityID.flatMap(library.identity)?.isHostCustom == true { copy.telnetIdentityID = nil }
        if host.proxy?.identityID.flatMap(library.identity)?.isHostCustom == true {
            copy.proxy?.identityID = nil
            copy.proxy?.username = ""
        }
        if host.telnetProxy?.identityID.flatMap(library.identity)?.isHostCustom == true {
            copy.telnetProxy?.identityID = nil
            copy.telnetProxy?.username = ""
        }
        copy.id = UUID()
        copy.name = String(localized: AppStrings.Vault.duplicatedHostName(host.name))
        library.upsert(copy)
    }

    func lastConnectedAt(for hostID: Host.ID) -> Date? {
        connectionHistory.mostRecentDate(for: hostID)
    }

    func snippetModifiedAt(for snippetID: Snippet.ID) -> Date {
        MobileSnippetTimestamp.resolve(
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

    func reconcileWorkspaceSessions(openSessionIDs: Set<String>, activeSessionID: String?) {
        orphanedSessionIDs = Set(workspaceSessions.map(\.id))
            .subtracting(openSessionIDs).subtracting(discardedSessionIDs)
        let target = activeSessionID.flatMap { id in workspaceSessions.first { $0.id == id } }
        if let target, openSessionIDs.contains(target.id) { recoverOrphanedWorkspaces(into: target) }
    }

    private func recoverOrphanedWorkspaces(into target: MobileWorkspaceSessionModel) {
        orphanedSessionIDs.remove(target.id)
        guard !target.isDiscarded else { return }
        for source in workspaceSessions where orphanedSessionIDs.contains(source.id) {
            let recovery = source.recovery
            var snapshot = workspaceSnapshot
            snapshot.sessions[source.id] = nil
            snapshot.sessions[target.id] = target.savedWorkspaceDescriptors + recovery.descriptors
            do {
                try workspaceStore.save(snapshot)
                workspaceSnapshot = snapshot
            } catch {
                self.error = String(localized: AppStrings.Workspace.workspaceChangesCouldNotBeSavedForTheNextLaunch)
                continue
            }
            recoveredWorkspaceIDs[source.id, default: []].formUnion(recovery.order)
            source.releaseForRecovery()
            target.acceptRecovery(recovery)
            orphanedSessionIDs.remove(source.id)
        }
    }

    func sceneChanged(_ id: UUID, phase: ScenePhase, workspaceSessionID: String? = nil) {
        if let workspaceSessionID { sceneSessionIDs[id] = workspaceSessionID }
        let wasBackground = allScenesAreBackgrounded
        scenePhases[id] = phase
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
            liveActivities.update(workspaceActivitySessions)
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
                commandHistory.clear(for: change.id)
                sftpHistory.clear(for: change.id)
                connectionHistory.clear(for: change.id)
                metrics.remove(change.id)
            }
        }
        forwardings.stop(plan.forwardingRuleIDs)
        library.replacePersistedSnapshot(snapshot)
        forwardings.reconcileConfiguration()
        liveActivities.update(workspaceActivitySessions)
    }

    func removeScene(_ id: UUID) {
        let wasBackground = allScenesAreBackgrounded
        scenePhases[id] = nil
        sceneSessionIDs[id] = nil
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
            for workspace in workspaces { workspace.suspendForBackgroundExpiration() }
            forwardings.stopAll()
            transfers.pauseAll()
            assistant.expireBackground()
        }
        liveActivities.update(workspaceActivitySessions)
    }

    func focusWorkspaceActivity(_ id: UUID) {
        liveActivities.focus(id, in: workspaceActivitySessions)
    }

    func workspaceSession(for id: String) -> MobileWorkspaceSessionModel {
        if let session = workspaceSessions.first(where: { $0.id == id }) { return session }
        var descriptors = workspaceSnapshot.sessions[id] ?? []
        if !hasBoundWorkspaceSession, !discardedSessionIDs.contains(id) {
            // A new process starts with one workspace window, even if UIKit restores several old scenes.
            // Keep records until ownership and the full consolidation can be saved together.
            var migrated = workspaceSnapshot
            descriptors = migrated.unassigned + migrated.sessions.keys.sorted().flatMap { migrated.sessions[$0] ?? [] }
            migrated.unassigned = []
            migrated.sessions = [id: descriptors]
            do {
                try workspaceStore.save(migrated)
                workspaceSnapshot = migrated
                hasBoundWorkspaceSession = true
            } catch {
                // Fence this launch too: another window must not claim the same recovery records.
                hasBoundWorkspaceSession = true
                descriptors = []
                self.error = String(localized: AppStrings.Workspace.restoreWorkspacesFailure)
            }
        }
        let session = MobileWorkspaceSessionModel(id: id, app: self, descriptors: descriptors)
        workspaceSessions.append(session)
        if discardedSessionIDs.contains(id) { session.discard() }
        return session
    }

    func workspaceOwner(_ workspaceID: UUID) -> String? {
        if let session = workspaceSessions.first(where: { $0.orderedWorkspaceItems.contains { $0.id == workspaceID } })
        {
            return session.id
        }
        return workspaceSnapshot.sessions.first(where: { $0.value.contains { $0.id == workspaceID } })?.key
    }

    func discardWorkspaceSessions(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        discardedSessionIDs.formUnion(ids)
        orphanedSessionIDs.subtract(ids)
        for id in Array(sceneSessionIDs.keys) where ids.contains(sceneSessionIDs[id] ?? "") { removeScene(id) }
        let recoveredIDs = ids.reduce(into: Set<UUID>()) { $0.formUnion(recoveredWorkspaceIDs[$1] ?? []) }
        for session in workspaceSessions {
            for workspaceID in recoveredIDs { session.close(workspaceID) }
        }
        for id in ids { recoveredWorkspaceIDs[id] = nil }
        for session in workspaceSessions where ids.contains(session.id) { session.discard() }
        workspaceSessions.removeAll { ids.contains($0.id) }
        // Before the first binding, these are records from the previous process awaiting consolidation.
        // UIKit discarding an old session must not erase them during cold launch.
        if hasBoundWorkspaceSession {
            for id in ids { workspaceSnapshot.sessions[id] = nil }
            persistWorkspaceSnapshot()
        }
    }

    func saveWorkspaceDescriptors(_ descriptors: [MobileWorkspaceDescriptor], for id: String) {
        guard !discardedSessionIDs.contains(id) else { return }
        workspaceSnapshot.sessions[id] = descriptors
        persistWorkspaceSnapshot()
    }

    private func loadRecentWorkspaces() {
        do {
            workspaceSnapshot = try workspaceStore.load()
            workspaceSnapshot.unassigned.removeAll { library.host($0.hostID) == nil }
            for id in workspaceSnapshot.sessions.keys {
                workspaceSnapshot.sessions[id]?.removeAll { library.host($0.hostID) == nil }
            }
            // Persist pruning with the first binding, so legacy migration and ownership stay atomic.
        } catch {
            self.error = String(localized: AppStrings.Workspace.restoreWorkspacesFailure)
        }
        liveActivities.update([])
    }

    private func persistWorkspaceSnapshot() {
        do {
            try workspaceStore.save(workspaceSnapshot)
        } catch {
            self.error = String(localized: AppStrings.Workspace.workspaceChangesCouldNotBeSavedForTheNextLaunch)
        }
    }

    func workspaceWillOpen(_ workspace: MobileWorkspace, close: @escaping (UUID) -> Void) {
        observeActivityState(of: workspace)
        workspace.didRequestClose = close
        startConnectionHistory(for: workspace)
    }

    func workspacesDidOpen(_ added: [MobileWorkspace]) {
        workspaceActivitySessions.append(contentsOf: added.map(\.activitySession))
        liveActivities.start(workspaceActivitySessions)
    }

    func workspaceDidClose(_ id: UUID) {
        endConnectionHistory(for: id)
        workspaceActivitySessions.removeAll { $0.id == id }
        liveActivities.update(workspaceActivitySessions)
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
            guard let self,
                let index = workspaceActivitySessions.firstIndex(where: { $0.id == session.id })
            else { return }
            workspaceActivitySessions[index] = session
            liveActivities.update(workspaceActivitySessions)
        }
    }
}
