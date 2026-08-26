import Foundation

@MainActor
struct AppDependencies {
    let hostRepository: any HostRepository
    let outboxRunner: OutboxRunner?
    let connectionCoordinator: RemoteConnectionCoordinator
    let agentRunRepository: (any AgentRunPersisting)?

    init(
        hostRepository: any HostRepository, outboxRunner: OutboxRunner?,
        connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator(),
        agentRunRepository: (any AgentRunPersisting)? = nil
    ) {
        self.hostRepository = hostRepository
        self.outboxRunner = outboxRunner
        self.connectionCoordinator = connectionCoordinator
        self.agentRunRepository = agentRunRepository
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
