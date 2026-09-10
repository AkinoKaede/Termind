import Foundation

nonisolated enum MetricsInterfaceKind: String, Sendable { case hardware, virtual, unknown }

nonisolated struct MetricsFilesystem: Identifiable, Sendable {
    var id: String { mountPoint + "\u{0}" + device }
    var mountPoint: String
    var device: String
    var type: String
    var blockID: String
    var used: Double?
    var total: Double?
    var usedPercent: Double?
}

nonisolated struct MetricsTCP: Sendable {
    var active: UInt64?
    var passive: UInt64?
    var failures: UInt64?
    var retransmitted: UInt64?
    var sent: UInt64?
}
