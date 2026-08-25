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

    static func legacy(hosts: HostStore) -> Self {
        Self(hostRepository: HostStoreRepositoryAdapter(store: hosts), outboxRunner: nil)
    }
}
