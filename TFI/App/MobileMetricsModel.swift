import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure

@MainActor
@Observable
final class MobileMetricsModel {
    private(set) var points: [UUID: MetricsPoint] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var selections: [MetricsSelection]
    private let defaults: UserDefaults?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        selections =
            defaults?.data(forKey: "mobile.metrics.v1").flatMap {
                try? JSONDecoder().decode([MetricsSelection].self, from: $0)
            } ?? []
    }

    func add(_ id: UUID, pro: Bool) -> Bool {
        if selections.contains(where: { $0.id == id }) { return true }
        guard pro || selections.count < 3 else { return false }
        selections.append(MetricsSelection(id: id))
        persist()
        return true
    }

    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        selections.removeAll { $0.id == id }
        points[id] = nil
        errors[id] = nil
        persist()
    }

    func pause() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func start(hosts: any RemoteSessionHostStore) {
        for selection in selections where selection.enabled && tasks[selection.id] == nil {
            guard let host = hosts.host(selection.id) else { continue }
            tasks[selection.id] = Task { [weak self] in
                let sampler = SSHMetricsSampler(session: SSHExecSession())
                do {
                    let config = try await hosts.prepareSSHConnection(for: host, submissions: [:]).resolve()
                    try await sampler.connect(config)
                    var previous: MetricsSample?
                    while !Task.isCancelled {
                        let sample = try await sampler.sample()
                        try Task.checkCancellation()
                        self?.points[host.id] = MetricsCalculation.point(
                            previous: previous, current: sample, selection: selection, date: .now)
                        self?.errors[host.id] = nil
                        previous = sample
                        try await Task.sleep(for: .seconds(3))
                    }
                } catch {
                    if !Task.isCancelled { self?.errors[host.id] = error.localizedDescription }
                }
                await sampler.disconnect()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(selections) { defaults?.set(data, forKey: "mobile.metrics.v1") }
    }
}
