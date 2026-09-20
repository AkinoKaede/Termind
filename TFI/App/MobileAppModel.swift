import Foundation
import Observation
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindRemoteInfrastructure

import struct TermindDomain.Host

private enum MobileWorkspaceStartup {
    case none
    case command(String)
    case directory(String)
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
    let commandHistory: CommandHistoryModel
    let sftpHistory: SFTPHistoryModel
    let connectionHistory: ConnectionHistoryModel
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
    private let defaults: UserDefaults?
    private let snippetTimestampFallback: Date
    private let background: any MobileBackgroundTaskManaging
    private let workspaceConnectionServices: MobileWorkspaceConnectionServices
    private let workspaceStore: MobileWorkspaceStore
    private(set) var savedWorkspaceDescriptors: [MobileWorkspaceDescriptor] = []

    var recentWorkspaces: [MobileWorkspaceDescriptor] {
        let opened = Set(workspaces.map(\.id))
        return savedWorkspaceDescriptors.filter { !opened.contains($0.id) }
    }

    let outbox: OutboxRunner
    private var scenePhases: [UUID: ScenePhase] = [:]

    convenience init(
        hosts: (any HostRepository)? = nil, inMemory: Bool = false, defaults: UserDefaults? = .standard,
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
            memoryOnly ? UserDefaults(suiteName: "termind.tests.\(UUID().uuidString)")! : defaults ?? .standard
        SettingsKey.migrateSyncPreferences(in: settingsDefaults)
        let settingsPersistence = SettingsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try settingsPersistence.prepare()
        let metricsPersistence = MetricsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try metricsPersistence.prepare()
        let aiSecrets = AISecretStore(context: settingsPersistence.context, keychain: secrets)
        terminalSettings = TerminalSettingsModel(persistence: settingsPersistence)
        sshSettings = SSHSettingsModel(persistence: settingsPersistence)
        sftpSettings = SFTPSettingsModel(persistence: settingsPersistence)
        connectionCoordinator.updateSSHPreferences(sshSettings.preferences)
        commandHistory = CommandHistoryModel(
            repository: SwiftDataCommandHistoryRepository(context: ModelContext(container)))
        sftpHistory = SFTPHistoryModel(
            repository: SwiftDataSFTPHistoryRepository(context: ModelContext(container)))
        connectionHistory = ConnectionHistoryModel(
            repository: SwiftDataConnectionHistoryRepository(context: ModelContext(container)))
        settingsSync =
            memoryOnly
            ? nil
            : SettingsSyncCoordinator(persistence: settingsPersistence, secrets: aiSecrets, defaults: settingsDefaults)
        metricsSync =
            memoryOnly
            ? nil
            : MetricsSyncCoordinator(persistence: metricsPersistence, defaults: settingsDefaults)
        vaultSync = memoryOnly ? nil : VaultSyncCoordinator(context: vaultContext, defaults: settingsDefaults)
        ai = AIConfigurationModel(
            persistence: SyncedAIConfigurationPersistence(settingsPersistence), secrets: secrets,
            permissionDefaults: settingsDefaults, aiSecrets: aiSecrets,
            webSearchPersistence: settingsPersistence)
        commandGenerator = CommandGeneratorController(ai: ai)
        skills = SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(settingsPersistence))
        memory = MemoryModel(
            storage: GRDBMemoryStore(directory: GRDBMemoryStore.defaultDirectory), defaults: settingsDefaults)
        library = HostLibraryModel(persistence: persistence, secrets: secrets)
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
        library.didChangeHostConnection = { [weak forwardings] in forwardings?.hostConfigurationChanged($0) }
        let visibleHostIDs = Set(try self.hosts.snapshot().value.hosts.map(\.id))
        for host in library.hosts where !visibleHostIDs.contains(host.id) { library.projectHostDeletion(host.id) }
        outbox.registerHostDeletionHandlers(
            repository: self.hosts,
            closeWorkspaces: { [weak self] payload in
                guard let self else { return }
                closeWorkspaces(for: payload.hostID)
                commandHistory.clear(for: payload.hostID)
                sftpHistory.clear(for: payload.hostID)
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
            self?.skills.applyRemoteSnapshot(snapshot.skills)
        }
        metricsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.metrics.core.applyRemoteSnapshot(snapshot)
        }
        loadRecentWorkspaces()
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

    /// Opens one independent SSH workspace per target. The command is intentionally
    /// carried only by the live workspace and never enters its restoration descriptor.
    func execute(_ snippet: Snippet, on hostIDs: [Host.ID]) -> [MobileWorkspace.ID] {
        let wanted = Set(hostIDs)
        let targets = library.searchHosts("").filter { wanted.contains($0.id) }
        let opened = targets.map { makeWorkspace(host: $0, kind: .ssh, startup: .command(snippet.body)) }
        addWorkspaces(opened)
        return opened.map(\.id)
    }

    @discardableResult
    func renameWorkspace(_ id: MobileWorkspace.ID, to title: String) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == id }), workspace.rename(to: title) else {
            return false
        }
        if let index = savedWorkspaceDescriptors.firstIndex(where: { $0.id == id }) {
            savedWorkspaceDescriptors[index] = workspace.descriptor
        }
        saveWorkspaces()
        return true
    }

    func close(_ id: UUID) {
        guard savedWorkspaceDescriptors.contains(where: { $0.id == id }) else { return }
        if let workspace = workspaces.first(where: { $0.id == id }) {
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.disconnect()
        }
        workspaces.removeAll { $0.id == id }
        savedWorkspaceDescriptors.removeAll { $0.id == id }
        saveWorkspaces()
        workspaceActivitySessions.removeAll { $0.id == id }
        liveActivities.update(workspaceActivitySessions)
    }

    func closeAll() {
        guard !savedWorkspaceDescriptors.isEmpty else { return }
        let closing = workspaces
        workspaces.removeAll()
        savedWorkspaceDescriptors.removeAll()
        saveWorkspaces()
        workspaceActivitySessions.removeAll()
        for workspace in closing {
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.disconnect()
        }
        liveActivities.update(workspaceActivitySessions)
    }

    private func closeWorkspaces(for hostID: UUID) {
        for descriptor in savedWorkspaceDescriptors where descriptor.hostID == hostID { close(descriptor.id) }
    }

    func deleteHost(_ id: UUID) {
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
        } catch { self.error = error.localizedDescription }
    }

    func duplicateHost(_ host: Host) {
        var copy = host
        copy.id = UUID()
        copy.name = String(localized: "\(host.name) copy")
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
        let wasBackground = !scenePhases.isEmpty && scenePhases.values.allSatisfy { $0 == .background }
        scenePhases[id] = phase
        let isBackground = scenePhases.values.allSatisfy { $0 == .background }
        if isBackground && !wasBackground {
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
        } else if phase == .active {
            sftpEdits.setMonitoring(true)
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
                metrics.remove(change.id)
            }
        }
        forwardings.stop(plan.forwardingRuleIDs)
        library.replacePersistedSnapshot(snapshot)
        forwardings.reconcileConfiguration()
        liveActivities.update(workspaceActivitySessions)
    }

    func removeScene(_ id: UUID) {
        scenePhases[id] = nil
        reconcileSync()
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
        connectionHistory.record(kind: descriptor.kind, for: descriptor.hostID)
        addWorkspaces([workspace])
        return workspace
    }

    private func loadRecentWorkspaces() {
        do {
            let descriptors = try workspaceStore.load()
            savedWorkspaceDescriptors = descriptors.filter { library.host($0.hostID) != nil }
            if savedWorkspaceDescriptors.count != descriptors.count { saveWorkspaces() }
        } catch {
            self.error = String(localized: "Saved workspaces could not be restored. The saved data has been kept.")
        }
        // No sessions exist at cold launch. Old URLs still resolve through the saved descriptors.
        liveActivities.update([])
    }

    private func saveWorkspaces() {
        do {
            try workspaceStore.save(savedWorkspaceDescriptors)
        } catch {
            self.error = String(localized: "Workspace changes could not be saved for the next launch.")
        }
    }

    private func makeWorkspace(
        host: Host, kind: ConnectionHistoryEntry.Kind, startup: MobileWorkspaceStartup = .none
    ) -> MobileWorkspace {
        connectionHistory.record(kind: kind, for: host.id)
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
        case (.ssh, .none), (.sftp, .none), (.sftp, .command):
            initialCommand = nil
            recordsInitialCommandInHistory = true
            initialSFTPPath = nil
        }
        let duplicateIndex = nextWorkspaceDuplicateIndex(hostID: host.id, kind: kind)
        let title = duplicateIndex == 0 ? host.name : "\(host.name) (\(duplicateIndex))"
        return MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(
                hostID: host.id, title: title, kind: kind, duplicateIndex: duplicateIndex),
            hosts: library, transfers: transfers, sftpEdits: sftpEdits, terminalSettings: terminalSettings,
            commandHistory: commandHistory, sftpHistory: sftpHistory,
            connectionServices: workspaceConnectionServices,
            initialCommand: initialCommand,
            recordsInitialCommandInHistory: recordsInitialCommandInHistory,
            initialSFTPPath: initialSFTPPath)
    }

    /// Gives a new workspace the lowest number not already held by the same
    /// connection kind on the same Host. A manual title does not release the
    /// allocation; only closing the workspace does.
    private func nextWorkspaceDuplicateIndex(
        hostID: Host.ID, kind: ConnectionHistoryEntry.Kind
    ) -> Int {
        let taken = Set(
            savedWorkspaceDescriptors.lazy
                .filter { $0.hostID == hostID && $0.kind == kind }
                .map(\.duplicateIndex)
        )
        var index = 0
        while taken.contains(index) { index += 1 }
        return index
    }

    private func addWorkspaces(_ added: [MobileWorkspace]) {
        guard !added.isEmpty else { return }
        for workspace in added { observeActivityState(of: workspace) }
        workspaces.append(contentsOf: added)
        let savedIDs = Set(savedWorkspaceDescriptors.map(\.id))
        savedWorkspaceDescriptors.append(contentsOf: added.map(\.descriptor).filter { !savedIDs.contains($0.id) })
        saveWorkspaces()
        workspaceActivitySessions.append(contentsOf: added.map(\.activitySession))
        liveActivities.start(workspaceActivitySessions)
        for workspace in added { workspace.connect() }
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
