import Foundation

public nonisolated struct MetricsCPUPoint: Identifiable, Equatable, Sendable {
    public var id: Int
    public var utilization: Double?
    public var user: Double?
    public var system: Double?
    public var wait: Double?
    public var steal: Double?
    public var idle: Double?

    public init(
        id: Int, utilization: Double? = nil, user: Double? = nil, system: Double? = nil,
        wait: Double? = nil, steal: Double? = nil, idle: Double? = nil
    ) {
        self.id = id
        self.utilization = utilization
        self.user = user
        self.system = system
        self.wait = wait
        self.steal = steal
        self.idle = idle
    }
}
