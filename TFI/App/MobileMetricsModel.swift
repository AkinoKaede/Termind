import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

/// The mobile shell delegates collection, authentication and retries to the desktop's shared model.
@MainActor
@Observable
final class MobileMetricsModel {
    let core: ServerMetricsModel
    private let hosts: any RemoteSessionHostStore
    private let limit = MobileMetricsLimit()
    var servers: [ServerMetric] { core.servers }
    var selections: [MetricsSelection] { servers.map(\.selection) }

    init(defaults: UserDefaults?, hosts: any RemoteSessionHostStore) {
        self.hosts = hosts
        let limit = limit
        core = ServerMetricsModel(
            hosts: hosts, preferences: MobileMetricsPreferences(defaults: defaults),
            makeSampler: { SSHMetricsSampler(session: SSHExecSession()) },
            discover: { host, proxy, jumps in
                try await SSHSessionActor.discoverHostKey(
                    hostID: host.id, host: host.host, port: host.port, proxy: proxy, jumps: jumps)
            }, cardLimit: { limit.maximum })
    }

    func add(_ id: UUID, pro: Bool) -> Bool {
        limit.maximum = pro ? nil : ServerMetricsModel.freeCardLimit
        guard let host = hosts.host(id) else { return false }
        return core.add(host)
    }

    func remove(_ id: UUID) { core.remove(id) }
    func pause() { core.suspend() }
    func start() {
        core.start()
        core.resume()
    }
}

@MainActor private final class MobileMetricsLimit { var maximum: Int? = 3 }

@MainActor private final class MobileMetricsPreferences: MetricsConfigurationStoring {
    private let defaults: UserDefaults?
    init(defaults: UserDefaults?) { self.defaults = defaults }
    func load() -> [MetricsSelection] {
        defaults?.data(forKey: "mobile.metrics.v1").flatMap {
            try? JSONDecoder().decode([MetricsSelection].self, from: $0)
        } ?? []
    }
    func save(_ values: [MetricsSelection]) {
        if let data = try? JSONEncoder().encode(values) { defaults?.set(data, forKey: "mobile.metrics.v1") }
    }
}
