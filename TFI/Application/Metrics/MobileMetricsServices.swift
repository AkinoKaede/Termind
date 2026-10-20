// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication

struct MobileMetricsServices {
    let makeSampler: @Sendable () -> any MetricsSampling

    static var testing: MobileMetricsServices {
        MobileMetricsServices(makeSampler: { preconditionFailure("Tests must not start live Metrics sampling") })
    }
}
