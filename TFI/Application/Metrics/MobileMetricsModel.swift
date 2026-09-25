import Foundation
import Observation
import TermindApplication
import TermindDomain

/// The mobile shell delegates collection, authentication and retries to the desktop's shared model.
@MainActor
@Observable
final class MobileMetricsModel {
    let core: ServerMetricsModel
    private let hosts: any RemoteSessionHostStore
    private let limit = MobileMetricsLimit()
    var servers: [ServerMetric] { core.servers }
    var selections: [MetricsSelection] { core.selections }

    init(
        preferences: any MetricsConfigurationStoring,
        hosts: any RemoteSessionHostStore,
        services: MobileMetricsServices
    ) {
        self.hosts = hosts
        let limit = limit
        core = ServerMetricsModel(
            hosts: hosts, preferences: preferences,
            makeSampler: services.makeSampler,
            cardLimit: { limit.maximum })
    }

    func add(_ id: UUID, pro: Bool) -> Bool {
        add([id], pro: pro)
    }

    func add(_ ids: [UUID], pro: Bool) -> Bool {
        limit.maximum = pro ? nil : ServerMetricsModel.freeCardLimit
        let batch = ids.compactMap(hosts.host)
        guard !batch.isEmpty else { return false }
        return core.add(batch)
    }

    func remove(_ id: UUID) { core.remove(id) }
    func pause() { core.suspend() }
    func start() {
        core.start()
        core.resume()
    }
}

@MainActor private final class MobileMetricsLimit { var maximum: Int? = 3 }
