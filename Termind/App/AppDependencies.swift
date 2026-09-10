import AgentKit
import Foundation

@MainActor
struct AppDependencies {
    let hostRepository: any HostRepository
    let outboxRunner: OutboxRunner?
    let connectionCoordinator: RemoteConnectionCoordinator
    let serialPortService: any SerialPortServing
    let agentRunRepository: (any AgentRunPersisting)?
    let settingsSync: SettingsSyncCoordinator?
    let vaultSync: VaultSyncCoordinator?

    init(
        hostRepository: any HostRepository, outboxRunner: OutboxRunner?,
        connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator(),
        serialPortService: any SerialPortServing = SystemSerialPortService(),
        agentRunRepository: (any AgentRunPersisting)? = nil,
        vaultSync: VaultSyncCoordinator? = nil,
        settingsSync: SettingsSyncCoordinator? = nil
    ) {
        self.hostRepository = hostRepository
        self.outboxRunner = outboxRunner
        self.connectionCoordinator = connectionCoordinator
        self.serialPortService = serialPortService
        self.agentRunRepository = agentRunRepository
        self.vaultSync = vaultSync
        self.settingsSync = settingsSync
    }

    static func inMemory(hosts: [Host], groups: [HostGroup]) -> Self {
        Self(
            hostRepository: InMemoryHostRepository(
                snapshot: HostLibrarySnapshot(hosts: hosts, groups: groups)
            ),
            outboxRunner: nil
        )
    }
}
