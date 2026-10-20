// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum MetricsInterfaceKind: String, Sendable { case hardware, virtual, unknown }

public nonisolated struct MetricsFilesystem: Identifiable, Sendable {
    public var id: String { mountPoint + "\u{0}" + device }
    public var mountPoint: String
    public var device: String
    public var type: String
    public var blockID: String
    public var used: Double?
    public var total: Double?
    public var usedPercent: Double?
    public init(
        mountPoint: String, device: String, type: String, blockID: String, used: Double? = nil, total: Double? = nil,
        usedPercent: Double? = nil
    ) {
        self.mountPoint = mountPoint
        self.device = device
        self.type = type
        self.blockID = blockID
        self.used = used
        self.total = total
        self.usedPercent = usedPercent
    }

}

public nonisolated struct MetricsTCP: Sendable {
    public var active: UInt64?
    public var passive: UInt64?
    public var failures: UInt64?
    public var retransmitted: UInt64?
    public var sent: UInt64?
    public init(
        active: UInt64? = nil, passive: UInt64? = nil, failures: UInt64? = nil, retransmitted: UInt64? = nil,
        sent: UInt64? = nil
    ) {
        self.active = active
        self.passive = passive
        self.failures = failures
        self.retransmitted = retransmitted
        self.sent = sent
    }

}
