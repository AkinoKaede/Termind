// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct MetricsCPUPoint: Identifiable, Equatable, Sendable {
    public var id: Int
    public var usage: MetricsCPUUsage

    public init(id: Int, usage: MetricsCPUUsage = .init()) {
        self.id = id
        self.usage = usage
    }
}
