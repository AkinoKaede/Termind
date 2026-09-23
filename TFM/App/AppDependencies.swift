import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
struct AppShutdownDependencies {
    let stopMCP: @MainActor () async -> Void
    let stopSFTP: @MainActor () async -> Void
    let closeAgentBackgroundCommands: @MainActor () async -> Void
    let closeAgentConnections: @MainActor () async -> Void
}

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
    let logging: any ApplicationLogManaging
    let settingsDefaults: UserDefaults
    let assistantConversations: AssistantConversationStore?
    let shutdown: AppShutdownDependencies?

    init(
        hostRepository: any HostRepository, outboxRunner: OutboxRunner?,
        connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator(),
        serialPortService: any SerialPortServing = SystemSerialPortService(),
        agentRunRepository: (any AgentRunPersisting)? = nil,
        vaultSync: VaultSyncCoordinator? = nil,
        settingsSync: SettingsSyncCoordinator? = nil,
        metricsSync: MetricsSyncCoordinator? = nil,
        metricsPreferences: (any MetricsConfigurationStoring)? = nil,
        mcpServerSecrets: any SecretStoring = InMemorySecretStore(),
        logging: any ApplicationLogManaging = DisabledApplicationLogManager.shared,
        settingsDefaults: UserDefaults = .standard,
        assistantConversations: AssistantConversationStore? = nil,
        shutdown: AppShutdownDependencies? = nil
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
        self.logging = logging
        self.settingsDefaults = settingsDefaults
        self.assistantConversations = assistantConversations
        self.shutdown = shutdown
    }

    static func inMemory(hosts: [Host], groups: [HostGroup]) -> Self {
        let defaults = UserDefaults(suiteName: "termind.tests.\(UUID().uuidString)")!
        SettingsKey.migrateSyncPreferences(in: defaults)
        return Self(
            hostRepository: InMemoryHostRepository(
                snapshot: HostLibrarySnapshot(hosts: hosts, groups: groups)
            ),
            outboxRunner: nil,
            settingsDefaults: defaults
        )
    }
}
