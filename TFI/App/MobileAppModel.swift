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

private enum MobileWorkspaceStartup {
    case none
    case command(String)
    case directory(String)
}

@MainActor
struct MobileWorkspaceItem: Identifiable {
    let descriptor: MobileWorkspaceDescriptor
    let workspace: MobileWorkspace?
    let host: Host?
    let loginAddress: String

    var id: MobileWorkspaceDescriptor.ID { descriptor.id }
}

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
    private(set) var workspaces: [MobileWorkspace] = []
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
    private let workspaceConnectionServices: MobileWorkspaceConnectionServices
    private let workspaceStore: MobileWorkspaceStore
    private(set) var savedWorkspaceDescriptors: [MobileWorkspaceDescriptor] = []
    private var workspaceDisplayOrder: [MobileWorkspaceDescriptor.ID] = []

    var recentWorkspaces: [MobileWorkspaceDescriptor] {
        let opened = Set(workspaces.map(\.id))
        return savedWorkspaceDescriptors.filter { !opened.contains($0.id) }
    }

    var orderedWorkspaceItems: [MobileWorkspaceItem] {
        workspaceDisplayOrder.compactMap { id in
            let workspace = workspaces.first { $0.id == id }
            guard let descriptor = workspace?.descriptor ?? savedWorkspaceDescriptors.first(where: { $0.id == id })
            else { return nil }
            let host = library.host(descriptor.hostID) ?? workspace?.presentationHost
            let loginAddress =
                workspace?.temporaryLoginAddress
                ?? host.map {
                    library.loginAddress(
                        for: $0,
                        protocol: descriptor.kind == .telnet ? .telnet : .ssh)
                }
                ?? descriptor.title
            return MobileWorkspaceItem(
                descriptor: descriptor,
                workspace: workspace,
                host: host,
                loginAddress: loginAddress)
        }
    }

    let outbox: OutboxRunner
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
        connectionHistoryRepository.didRecordVaultChanges = { [weak vaultSync] in
            vaultSync?.noteLocalChanges($0)
        }
        deviceDirectoryRepository.didRecordVaultChanges = { [weak vaultSync] in
            vaultSync?.noteLocalChanges($0)
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
            repository.didRecordVaultChanges = { [weak vaultSync] in vaultSync?.noteLocalChanges($0) }
        }
        vaultSync?.didApplyRemote = { [weak self] in self?.applyRemoteVault($0, keys: $1) }
        sftpSettings.didChange = { [weak transfers] preferences in
            transfers?.updatePreferences(preferences)
        }
        sshSettings.didChange = { preferences in
            connectionCoordinator.updateSSHPreferences(preferences)
        }
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

    func open(
        hostID: UUID, kind: ConnectionHistoryEntry.Kind,
        initialPath: String? = nil
    ) -> UUID? {
        guard let host = library.host(hostID) else { return nil }
        let startup: MobileWorkspaceStartup
        if let initialPath,
            !initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            startup = .directory(RemotePath.normalized(initialPath))
        } else {
            startup = .none
        }
        let workspace = makeWorkspace(host: host, kind: kind, startup: startup)
        addWorkspaces([workspace])
        return workspace.id
    }

    func openExternalConnection(_ request: RemoteConnectionURL) -> MobileWorkspace.ID {
        let host: Host
        let kind: ConnectionHistoryEntry.Kind
        switch request.kind {
        case .ssh:
            host = Host(name: request.host, host: request.host, port: request.port)
            kind = .ssh
        case .sftp:
            host = Host(name: request.host, host: request.host, port: request.port)
            kind = .sftp
        case .telnet:
            host = Host(
                name: request.host, host: request.host,
                sshEnabled: false, telnetEnabled: true, telnetPort: request.port)
            kind = .telnet
        }
        let route = SSHConnectionRoute(
            hosts: [host], usernames: request.username.map { [host.id: $0] } ?? [:])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(
                hostID: host.id, title: host.name, kind: kind),
            hosts: library, transfers: transfers, sftpEdits: sftpEdits,
            terminalSettings: terminalSettings, commandHistory: commandHistory,
            sftpHistory: sftpHistory, connectionServices: workspaceConnectionServices,
            transientHost: host,
            connectionRoute: request.kind == .telnet ? nil : route,
            usernameHint: request.username,
            connectionOrigin: .externalLink(
                hostKeyConstraints: request.hostKeyFingerprint.map { [host.id: $0] } ?? [:]),
            advisoryTelnetPassword: request.advisoryPassword.map(SSHSecret.init),
            externalSFTPResourcePath: request.kind == .sftp ? request.path : nil,
            externalSFTPMustBeDirectory: request.sftpType == .directory)
        addWorkspaces([workspace], persists: false)
        return workspace.id
    }

    /// Opens one independent SSH workspace per target. The command is intentionally
    /// carried only by the live workspace and never enters its restoration descriptor.
    func execute(_ snippet: Snippet, on hostIDs: [Host.ID]) -> [MobileWorkspace.ID] {
        let wanted = Set(hostIDs)
        let targets = library.hosts(matching: "", for: .snippetExecution)
            .filter { wanted.contains($0.id) }
        let opened = targets.map { makeWorkspace(host: $0, kind: .ssh, startup: .command(snippet.body)) }
        addWorkspaces(opened)
        return opened.map(\.id)
    }

    @discardableResult
    func renameWorkspace(_ id: MobileWorkspace.ID, to title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let workspace = workspaces.first { $0.id == id }
        let savedIndex = savedWorkspaceDescriptors.firstIndex { $0.id == id }
        guard workspace != nil || savedIndex != nil else { return false }
        if let workspace {
            guard workspace.rename(to: title) else { return false }
        } else {
            guard let savedIndex, savedWorkspaceDescriptors[savedIndex].title != title else { return false }
            savedWorkspaceDescriptors[savedIndex].title = title
        }
        if let savedIndex, let workspace {
            savedWorkspaceDescriptors[savedIndex] = workspace.descriptor
        }
        saveWorkspaces()
        return true
    }

    func close(_ id: UUID) {
        let wasSaved = savedWorkspaceDescriptors.contains(where: { $0.id == id })
        guard wasSaved || workspaces.contains(where: { $0.id == id }) else { return }
        endConnectionHistory(for: id)
        if let workspace = workspaces.first(where: { $0.id == id }) {
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.disconnect()
        }
        workspaces.removeAll { $0.id == id }
        savedWorkspaceDescriptors.removeAll { $0.id == id }
        workspaceDisplayOrder.removeAll { $0 == id }
        if wasSaved { saveWorkspaces() }
        workspaceActivitySessions.removeAll { $0.id == id }
        liveActivities.update(workspaceActivitySessions)
    }

    var closableWorkspaceCount: Int {
        Set(savedWorkspaceDescriptors.map(\.id)).union(workspaces.map(\.id)).count
    }

    func closeOtherWorkspaces(than id: MobileWorkspace.ID) {
        let knownIDs = Set(savedWorkspaceDescriptors.map(\.id)).union(workspaces.map(\.id))
        guard knownIDs.contains(id), knownIDs.count > 1 else { return }

        let closing = workspaces.filter { $0.id != id }
        workspaces.removeAll { $0.id != id }
        savedWorkspaceDescriptors.removeAll { $0.id != id }
        workspaceDisplayOrder.removeAll { $0 != id }
        saveWorkspaces()
        workspaceActivitySessions.removeAll { $0.id != id }
        for workspace in closing {
            endConnectionHistory(for: workspace.id)
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.disconnect()
        }
        liveActivities.update(workspaceActivitySessions)
    }

    func closeAll() {
        guard !savedWorkspaceDescriptors.isEmpty || !workspaces.isEmpty else { return }
        let closing = workspaces
        workspaces.removeAll()
        savedWorkspaceDescriptors.removeAll()
        workspaceDisplayOrder.removeAll()
        saveWorkspaces()
        workspaceActivitySessions.removeAll()
        for workspace in closing {
            endConnectionHistory(for: workspace.id)
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.disconnect()
        }
        liveActivities.update(workspaceActivitySessions)
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
        for descriptor in savedWorkspaceDescriptors where descriptor.hostID == hostID { close(descriptor.id) }
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

    func sceneChanged(_ id: UUID, phase: ScenePhase) {
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
            metricsSync?.start()
            settingsSync?.start()
        } else {
            vaultSync?.pause()
            metricsSync?.pause()
            settingsSync?.pause()
        }
    }

    func setSyncEnabled(_ value: Bool, key: String) {
        guard !value || pro.require(.vaultSync) else { return }
        defaults?.set(value, forKey: key)
        if value && (key == SettingsKey.iCloudSyncEnabled || key == SettingsKey.vaultSyncEnabled) {
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
        if keys.contains(where: { $0.kind == .connectionHistory }) {
            connectionHistory.reload()
        }
        if keys.contains(where: { $0.kind == .device }) { devices.reload() }
        forwardings.reconcileConfiguration()
        liveActivities.update(workspaceActivitySessions)
    }

    func removeScene(_ id: UUID) {
        let wasBackground = allScenesAreBackgrounded
        scenePhases[id] = nil
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

    /// Publish before connecting so every scene shares one instance and one initial attempt.
    @discardableResult
    func openWorkspace(_ id: UUID) -> MobileWorkspace? {
        if let workspace = workspaces.first(where: { $0.id == id }) { return workspace }
        guard let descriptor = savedWorkspaceDescriptors.first(where: { $0.id == id }) else { return nil }
        guard library.host(descriptor.hostID) != nil else {
            close(id)
            return nil
        }
        let workspace = MobileWorkspace(
            descriptor: descriptor, hosts: library, transfers: transfers, sftpEdits: sftpEdits,
            terminalSettings: terminalSettings, commandHistory: commandHistory, sftpHistory: sftpHistory,
            connectionServices: workspaceConnectionServices)
        addWorkspaces([workspace])
        return workspace
    }

    private func loadRecentWorkspaces() {
        do {
            let descriptors = try workspaceStore.load()
            savedWorkspaceDescriptors = descriptors.filter { library.host($0.hostID) != nil }
            workspaceDisplayOrder = savedWorkspaceDescriptors.map(\.id)
            if savedWorkspaceDescriptors.count != descriptors.count { saveWorkspaces() }
        } catch {
            self.error = String(localized: AppStrings.Workspace.restoreWorkspacesFailure)
        }
        // No sessions exist at cold launch. Old URLs still resolve through the saved descriptors.
        liveActivities.update([])
    }

    private func saveWorkspaces() {
        do {
            try workspaceStore.save(savedWorkspaceDescriptors)
        } catch {
            self.error = String(localized: AppStrings.Workspace.workspaceChangesCouldNotBeSavedForTheNextLaunch)
        }
    }

    private func makeWorkspace(
        host: Host, kind: ConnectionHistoryEntry.Kind, startup: MobileWorkspaceStartup = .none
    ) -> MobileWorkspace {
        let initialCommand: String?
        let recordsInitialCommandInHistory: Bool
        let initialSFTPPath: String?
        switch (kind, startup) {
        case (.ssh, .command(let command)):
            initialCommand = command
            recordsInitialCommandInHistory = true
            initialSFTPPath = nil
        case (.ssh, .directory(let path)):
            initialCommand = RemoteShellCommand.changeDirectory(to: path)
            recordsInitialCommandInHistory = false
            initialSFTPPath = nil
        case (.sftp, .directory(let path)):
            initialCommand = nil
            recordsInitialCommandInHistory = true
            initialSFTPPath = path
        case (.ssh, .none), (.sftp, .none), (.sftp, .command),
            (.telnet, .none), (.telnet, .command), (.telnet, .directory):
            initialCommand = nil
            recordsInitialCommandInHistory = true
            initialSFTPPath = nil
        }
        let title = WorkspaceNameAllocator.nextName(
            prefix: host.name,
            occupiedNames: savedWorkspaceDescriptors.map(\.title),
            automaticallyRenames: workspaceSettings.preferences.automaticallyRenamesWorkspaces)
        return MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(
                hostID: host.id, title: title, kind: kind),
            hosts: library, transfers: transfers, sftpEdits: sftpEdits, terminalSettings: terminalSettings,
            commandHistory: commandHistory, sftpHistory: sftpHistory,
            connectionServices: workspaceConnectionServices,
            initialCommand: initialCommand,
            recordsInitialCommandInHistory: recordsInitialCommandInHistory,
            initialSFTPPath: initialSFTPPath)
    }

    private func addWorkspaces(_ added: [MobileWorkspace], persists: Bool = true) {
        guard !added.isEmpty else { return }
        var orderedIDs = Set(workspaceDisplayOrder)
        for id in added.map(\.id) where orderedIDs.insert(id).inserted {
            workspaceDisplayOrder.append(id)
        }
        for workspace in added {
            observeActivityState(of: workspace)
            startConnectionHistory(for: workspace)
        }
        workspaces.append(contentsOf: added)
        if persists {
            let savedIDs = Set(savedWorkspaceDescriptors.map(\.id))
            savedWorkspaceDescriptors.append(contentsOf: added.map(\.descriptor).filter { !savedIDs.contains($0.id) })
            saveWorkspaces()
        }
        workspaceActivitySessions.append(contentsOf: added.map(\.activitySession))
        liveActivities.start(workspaceActivitySessions)
        for workspace in added { workspace.connect() }
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
        workspace.didRequestClose = { [weak self] id in
            self?.close(id)
        }
        workspace.didChangeState = { [weak self] session in
            guard let self,
                let index = workspaceActivitySessions.firstIndex(where: { $0.id == session.id })
            else { return }
            workspaceActivitySessions[index] = session
            liveActivities.update(workspaceActivitySessions)
        }
    }
}
