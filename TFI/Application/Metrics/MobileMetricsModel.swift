// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
    var servers: [ServerMetric] { core.servers }
    var selections: [MetricsSelection] { core.selections }

    init(
        preferences: any MetricsConfigurationStoring,
        hosts: any RemoteSessionHostStore,
        services: MobileMetricsServices
    ) {
        self.hosts = hosts
        core = ServerMetricsModel(
            hosts: hosts, preferences: preferences,
            makeSampler: services.makeSampler)
    }

    func add(_ id: UUID) -> Bool {
        add([id])
    }

    func add(_ ids: [UUID]) -> Bool {

        let batch = ids.compactMap(hosts.host)
        guard !batch.isEmpty else { return false }
        return core.add(batch)
    }

    func remove(_ id: UUID) { core.remove(id) }

    func replaceHosts(selectedIDs: [UUID], editableHostIDs: Set<UUID>) -> Bool {

        return core.replaceHosts(selectedIDs: selectedIDs, editableHostIDs: editableHostIDs)
    }
    func pause() { core.suspend() }
    func start() {
        core.start()
        core.resume()
    }
}
