import Foundation

/// Counter-derived CPU percentages, shared by the aggregate and each logical core.
public nonisolated struct MetricsCPUUsage: Equatable, Sendable {
    public var utilization: Double?
    public var user: Double?
    public var system: Double?
    public var wait: Double?
    public var steal: Double?
    public var idle: Double?

    public init(
        utilization: Double? = nil, user: Double? = nil, system: Double? = nil,
        wait: Double? = nil, steal: Double? = nil, idle: Double? = nil
    ) {
        self.utilization = utilization
        self.user = user
        self.system = system
        self.wait = wait
        self.steal = steal
        self.idle = idle
    }
}
