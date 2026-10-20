// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindRemoteInfrastructure

extension MobileMetricsServices {
    static var live: MobileMetricsServices {
        live(coordinator: RemoteConnectionCoordinator())
    }

    static func live(coordinator: RemoteConnectionCoordinator) -> MobileMetricsServices {
        MobileMetricsServices(makeSampler: { coordinator.makeMetricsSampler() })
    }
}
