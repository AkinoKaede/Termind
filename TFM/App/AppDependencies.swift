import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
struct AppDependencies {
    let hostRepository: any HostRepository
    let outboxRunner: OutboxRunner?
    let connectionCoordinator: RemoteConnectionCoordinator
    let serialPortService: any SerialPortServing
    let agentRunRepository: (any AgentRunPersisting)?
    let settingsSync: SettingsSyncCoordinator?
    let metricsSync: MetricsSyncCoordinator?
    let vaultSync: VaultSyncCoordinator?
    let metricsPreferences: (any MetricsConfigurationStoring)?
    let mcpServerSecrets: any SecretStoring

    init(
        hostRepository: any HostRepository, outboxRunner: OutboxRunner?,
        connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator(),
        serialPortService: any SerialPortServing = SystemSerialPortService(),
        agentRunRepository: (any AgentRunPersisting)? = nil,
        vaultSync: VaultSyncCoordinator? = nil,
        settingsSync: SettingsSyncCoordinator? = nil,
        metricsSync: MetricsSyncCoordinator? = nil,
        metricsPreferences: (any MetricsConfigurationStoring)? = nil,
        mcpServerSecrets: any SecretStoring = InMemorySecretStore()
    ) {
        self.hostRepository = hostRepository
        self.outboxRunner = outboxRunner
        self.connectionCoordinator = connectionCoordinator
        self.serialPortService = serialPortService
        self.agentRunRepository = agentRunRepository
        self.vaultSync = vaultSync
        self.settingsSync = settingsSync
        self.metricsSync = metricsSync
        self.metricsPreferences = metricsPreferences
        self.mcpServerSecrets = mcpServerSecrets
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
