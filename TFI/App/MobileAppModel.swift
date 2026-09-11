import Foundation
import Observation
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindRemoteInfrastructure

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
    let transfers: SFTPTransferCoordinator
    private(set) var workspaces: [MobileWorkspace] = []
    var error: String?
    let terminalSettings: TerminalSettingsModel
    let commandHistory: CommandHistoryModel
    let vaultSync: VaultSyncCoordinator?
    let settingsSync: SettingsSyncCoordinator?
    let ai: AIConfigurationModel
    let assistant: MobileAssistantModel
    let metrics: MobileMetricsModel
    let pro: ProAccessController
    let liveActivities: MobileLiveActivityController
    private let defaults: UserDefaults?
    private let background = MobileBackgroundController()
    let outbox: OutboxRunner
    private var hasActivated = false
    private var scenePhases: [UUID: ScenePhase] = [:]

    init(hosts: (any HostRepository)? = nil, inMemory: Bool = false, defaults: UserDefaults? = .standard) throws {
        let memoryOnly = inMemory || hosts != nil
        let storeURL = URL.applicationSupportDirectory.appending(path: "Termind.store")
        if !memoryOnly {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        container = try TermindPersistence.makeContainer(inMemory: memoryOnly, url: memoryOnly ? nil : storeURL)
        let vaultContext = ModelContext(container)
        self.hosts = hosts ?? SwiftDataHostRepository(context: vaultContext)
        outbox = OutboxRunner(store: SwiftDataOutboxStore(context: ModelContext(container)))
        self.defaults = inMemory || hosts != nil ? nil : defaults
        liveActivities = MobileLiveActivityController(enabled: !inMemory && hosts == nil)
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
        SharedSettingsKey.migrateSyncPreferences(in: settingsDefaults)
        let settingsPersistence = SettingsSyncPersistence(context: ModelContext(container), defaults: settingsDefaults)
        try settingsPersistence.prepare()
        let aiSecrets = AISecretStore(context: settingsPersistence.context, keychain: secrets)
        terminalSettings = TerminalSettingsModel(persistence: settingsPersistence)
        commandHistory = CommandHistoryModel(
            repository: SwiftDataCommandHistoryRepository(context: ModelContext(container)))
        settingsSync =
            memoryOnly
            ? nil
            : SettingsSyncCoordinator(persistence: settingsPersistence, secrets: aiSecrets, defaults: settingsDefaults)
        vaultSync = memoryOnly ? nil : VaultSyncCoordinator(context: vaultContext, defaults: settingsDefaults)
        ai = AIConfigurationModel(
            persistence: SyncedAIConfigurationPersistence(settingsPersistence), secrets: secrets,
            aiSecrets: aiSecrets, webSearchPersistence: settingsPersistence)
        assistant = MobileAssistantModel(
            configuration: ai, repository: SwiftDataAgentRunRepository(context: ModelContext(container)))
        library = HostLibraryModel(persistence: persistence, secrets: secrets)
        metrics = MobileMetricsModel(defaults: memoryOnly ? nil : defaults, hosts: library)
        credentials = CredentialLibraryModel(library: library)
        snippets = SnippetLibraryModel(library: library)
        knownHosts = KnownHostsLibraryModel(library: library)
        forwardingLibrary = ForwardingLibraryModel(library: library)
        forwardings = PortForwardingController(hosts: library)
        transfers = SFTPTransferCoordinator(store: library, clientFactory: { SFTPClient() })
        library.willDeletePortForwardings = { [weak forwardings] ids in forwardings?.stop(ids) }
        let visibleHostIDs = Set(try self.hosts.snapshot().value.hosts.map(\.id))
        for host in library.hosts where !visibleHostIDs.contains(host.id) { library.projectHostDeletion(host.id) }
        outbox.register(
            RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.closeWorkspaces) { [weak self] payload in
                guard let self else { return }
                for workspace in workspaces.filter({ $0.descriptor.hostID == payload.hostID }) { close(workspace.id) }
                commandHistory.clear(for: payload.hostID)
                library.projectHostDeletion(payload.hostID)
            })
        outbox.register(
            RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.cancelTransfers) { [weak self] payload in
                guard let self else { return }
                transfers.cancelAll(for: payload.hostID)
            })
        outbox.register(
            RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.stopForwardings) { [weak forwardings] payload in
                forwardings?.stop(payload.forwardingRuleIDs)
            })
        outbox.register(
            RepositoryHostDeletionHandler(handlerID: HostDeletionOutbox.clearReferences, repository: self.hosts))
        outbox.register(RepositoryHostDeletionHandler(handlerID: HostDeletionOutbox.finalize, repository: self.hosts))
        library.didRecordVaultChanges = { [weak vaultSync] in vaultSync?.noteLocalChanges($0) }
        if let repository = self.hosts as? SwiftDataHostRepository {
            repository.didRecordVaultChanges = { [weak vaultSync] in vaultSync?.noteLocalChanges($0) }
        }
        vaultSync?.didApplyRemote = { [weak self] in self?.applyRemoteVault($0, keys: $1) }
        settingsSync?.didApplyRemote = { [weak self] snapshot, _ in
            self?.ai.applyRemoteSnapshot(snapshot.configuration, webSearch: snapshot.webSearch)
            self?.terminalSettings.applyRemoteSnapshot(snapshot.terminal)
        }
        if let data = self.defaults?.data(forKey: "mobile.workspaces.v1") {
            let descriptors = try JSONDecoder().decode([MobileWorkspaceDescriptor].self, from: data)
            workspaces = descriptors.filter { library.host($0.hostID) != nil }.map {
                MobileWorkspace(
                    descriptor: $0, hosts: library, transfers: transfers, terminalSettings: terminalSettings,
                    commandHistory: commandHistory)
            }
            for workspace in workspaces {
                workspace.didChangeState = { [weak self] in
                    guard let self else { return }
                    liveActivities.update(workspaces)
                }
            }
        }
    }

    func open(hostID: UUID, kind: MobileWorkspaceDescriptor.Kind) -> UUID? {
        guard let host = library.host(hostID) else { return nil }
        let descriptor = MobileWorkspaceDescriptor(hostID: hostID, title: host.name, kind: kind)
        let workspace = MobileWorkspace(
            descriptor: descriptor, hosts: library, transfers: transfers, terminalSettings: terminalSettings,
            commandHistory: commandHistory)
        workspaces.append(workspace)
        persistWorkspaces()
        workspace.didChangeState = { [weak self] in
            guard let self else { return }
            liveActivities.update(workspaces)
        }
        liveActivities.start(workspaces)
        workspace.connect()
        return workspace.id
    }

    func close(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        workspace.disconnect()
        workspaces.removeAll { $0.id == id }
        liveActivities.update(workspaces)
        persistWorkspaces()
    }

    func deleteHost(_ id: UUID) {
        do {
            for workspace in workspaces.filter({ $0.descriptor.hostID == id }) { close(workspace.id) }
            transfers.cancelAll(for: id)
            forwardings.stop(library.portForwardings(for: id).map(\.id))
            metrics.remove(id)
            try hosts.requestHostDeletion(id)
            library.projectHostDeletion(id)
            outbox.start()
        } catch { self.error = error.localizedDescription }
    }

    func sceneChanged(_ id: UUID, phase: ScenePhase) {
        let wasBackground = !scenePhases.isEmpty && scenePhases.values.allSatisfy { $0 == .background }
        scenePhases[id] = phase
        let isBackground = scenePhases.values.allSatisfy { $0 == .background }
        if isBackground && !wasBackground {
            vaultSync?.pause()
            settingsSync?.pause()
            metrics.pause()
            outbox.stop()
            assistant.stop()
            background.begin { [weak self] in
                guard let self else { return }
                for workspace in workspaces { workspace.disconnect() }
                forwardings.stopAll()
                transfers.cancelAll()
            }
            liveActivities.update(workspaces)
        } else if phase == .active {
            background.finish()
            reconcileSync()
            outbox.start()
            if hasActivated {
                liveActivities.update(workspaces)
            } else {
                hasActivated = true
                liveActivities.start(workspaces)
            }
            metrics.start()
        }
    }

    func reconcileSync() {
        let foreground = scenePhases.values.contains(.active)
        if foreground && pro.canUse(.vaultSync) {
            vaultSync?.start()
            settingsSync?.start()
        } else {
            vaultSync?.pause()
            settingsSync?.pause()
        }
    }

    func setSyncEnabled(_ value: Bool, key: String) {
        guard !value || pro.require(.vaultSync) else { return }
        defaults?.set(value, forKey: key)
        reconcileSync()
    }

    func applyRemoteVault(_ snapshot: VaultSnapshot, keys: Set<VaultRecordKey>) {
        let changed = Set(keys.filter { $0.kind == .host }.map(\.id))
        for id in changed {
            guard let old = library.host(id) else { continue }
            let next = snapshot.hosts.first { $0.id == id }
            let removed = next == nil
            let routeChanged =
                next.map {
                    old.host != $0.host || old.port != $0.port || old.identityID != $0.identityID
                        || old.jumpHostID != $0.jumpHostID || old.proxy != $0.proxy
                } ?? true
            if routeChanged {
                for workspace in workspaces.filter({ $0.descriptor.hostID == id }) {
                    if removed { close(workspace.id) } else { workspace.disconnect() }
                }
                transfers.cancelAll(for: id)
                forwardings.stop(library.portForwardings(for: id).map(\.id))
            }
            if removed {
                commandHistory.clear(for: id)
                metrics.remove(id)
            }
        }
        forwardings.stop(keys.filter { $0.kind == .portForwarding }.map(\.id))
        library.replacePersistedSnapshot(snapshot)
        liveActivities.update(workspaces)
    }

    func removeScene(_ id: UUID) {
        scenePhases[id] = nil
        reconcileSync()
    }

    private func persistWorkspaces() {
        do {
            defaults?.set(try JSONEncoder().encode(workspaces.map(\.descriptor)), forKey: "mobile.workspaces.v1")
        } catch { self.error = error.localizedDescription }
    }
}

nonisolated enum MobileDestination: String, CaseIterable, Identifiable {
    case vault, metrics, workspaces, assistant, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .vault: String(localized: "Vault")
        case .assistant: String(localized: "Assistant")
        case .workspaces: String(localized: "Workspaces")
        case .metrics: String(localized: "Metrics")
        case .settings: String(localized: "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .vault: "server.rack"
        case .assistant: "sparkles"
        case .workspaces: "terminal"
        case .metrics: "gauge.with.dots.needle.33percent"
        case .settings: "gearshape"
        }
    }
}
