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
    let ai: AIConfigurationModel
    let assistant: MobileAssistantModel
    let metrics: MobileMetricsModel
    let pro: ProAccessController
    let liveActivities: MobileLiveActivityController
    private let defaults: UserDefaults?
    private let background = MobileBackgroundController()
    let outbox: OutboxRunner
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
        metrics = MobileMetricsModel(defaults: inMemory || hosts != nil ? nil : defaults)
        pro = inMemory || hosts != nil ? .unrestrictedForTesting() : .live()
        let persistence = HostPersistence(context: vaultContext)
        _ = try persistence.load()
        let secrets: any SecretStoring =
            inMemory || hosts != nil
            ? InMemorySecretStore()
            : KeychainSecretStore(
                accessGroup: Bundle.main.object(forInfoDictionaryKey: "TermindKeychainAccessGroup") as? String
                    ?? "F6SUNDBBN9.com.akinokaede.termind")
        let aiPersistence = AIPersistence(context: ModelContext(container))
        _ = try aiPersistence.load()
        ai = AIConfigurationModel(
            persistence: aiPersistence, secrets: secrets,
            aiSecrets: AISecretStore(context: ModelContext(container), keychain: secrets))
        assistant = MobileAssistantModel(
            configuration: ai, repository: SwiftDataAgentRunRepository(context: ModelContext(container)))
        library = HostLibraryModel(persistence: persistence, secrets: secrets)
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
        if let data = self.defaults?.data(forKey: "mobile.workspaces.v1") {
            let descriptors = try JSONDecoder().decode([MobileWorkspaceDescriptor].self, from: data)
            workspaces = descriptors.filter { library.host($0.hostID) != nil }.map {
                MobileWorkspace(descriptor: $0, hosts: library, transfers: transfers)
            }
            for workspace in workspaces {
                workspace.didChangeState = { [weak self] in
                    guard let self else { return }
                    liveActivities.update(workspaces)
                }
            }
        }
    }

    func makeSSHImportModel() -> SSHImportModel {
        SSHImportModel(library: library, reader: SSHImportReader(username: ""))
    }

    func open(hostID: UUID, kind: MobileWorkspaceDescriptor.Kind) -> UUID? {
        guard let host = library.host(hostID) else { return nil }
        let descriptor = MobileWorkspaceDescriptor(hostID: hostID, title: host.name, kind: kind)
        let workspace = MobileWorkspace(descriptor: descriptor, hosts: library, transfers: transfers)
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
            outbox.start()
            liveActivities.update(workspaces)
            metrics.start(hosts: library)
        }
    }

    func removeScene(_ id: UUID) { scenePhases[id] = nil }

    private func persistWorkspaces() {
        do {
            defaults?.set(try JSONEncoder().encode(workspaces.map(\.descriptor)), forKey: "mobile.workspaces.v1")
        } catch { self.error = error.localizedDescription }
    }
}

nonisolated enum MobileDestination: String, CaseIterable, Identifiable {
    case welcome, hosts, assistant, workspaces, metrics, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .hosts: String(localized: "Vault")
        case .assistant: String(localized: "Assistant")
        case .workspaces: String(localized: "Workspaces")
        case .metrics: String(localized: "Metrics")
        case .settings: String(localized: "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "house"
        case .hosts: "server.rack"
        case .assistant: "sparkles"
        case .workspaces: "terminal"
        case .metrics: "gauge.with.dots.needle.33percent"
        case .settings: "gearshape"
        }
    }
}
