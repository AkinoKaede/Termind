import Foundation

@MainActor
struct AppDependencies {
    let hostRepository: any HostRepository
    let outboxRunner: OutboxRunner?
    let connectionCoordinator: RemoteConnectionCoordinator

    init(
        hostRepository: any HostRepository, outboxRunner: OutboxRunner?,
        connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator()
    ) {
        self.hostRepository = hostRepository
        self.outboxRunner = outboxRunner
        self.connectionCoordinator = connectionCoordinator
    }

    static func legacy(hosts: HostStore) -> Self {
        Self(hostRepository: HostStoreRepositoryAdapter(store: hosts), outboxRunner: nil)
    }
}
