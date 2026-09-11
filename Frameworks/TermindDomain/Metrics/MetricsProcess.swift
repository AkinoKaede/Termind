import Foundation

public nonisolated struct MetricsProcessCounter: Sendable {
    public var pid: Int
    public var name: String
    public var ticks: UInt64
    public var started: UInt64
    public var memory: Double?
    public init(pid: Int, name: String, ticks: UInt64, started: UInt64, memory: Double? = nil) {
        self.pid = pid
        self.name = name
        self.ticks = ticks
        self.started = started
        self.memory = memory
    }

}

public nonisolated struct MetricsProcessSample: Sendable {
    public var cpu: [UInt64]
    public var coreCount: Int
    public var processes: [MetricsProcessCounter]
    public init(cpu: [UInt64], coreCount: Int, processes: [MetricsProcessCounter]) {
        self.cpu = cpu
        self.coreCount = coreCount
        self.processes = processes
    }

}

public nonisolated struct MetricsProcess: Identifiable, Sendable {
    public var id: String { "\(pid):\(started)" }
    public var pid: Int
    public var started: UInt64
    public var name: String
    public var cpu: Double?
    public var memory: Double?
    public var cpuSortValue: Double { cpu ?? -1 }
    public var memorySortValue: Double { memory ?? -1 }

    public static func rows(previous: MetricsProcessSample?, current: MetricsProcessSample) -> [Self] {
        let old = Dictionary((previous?.processes ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
        var elapsedTicks: Double?
        if let previous, previous.coreCount == current.coreCount, previous.cpu.count >= 8, current.cpu.count >= 8,
            (0..<8).allSatisfy({ current.cpu[$0] >= previous.cpu[$0] })
        {
            let delta = (0..<8).reduce(0.0) { $0 + Double(current.cpu[$1] - previous.cpu[$1]) }
            if delta > 0 { elapsedTicks = delta }
        }
        return current.processes.map { process in
            var cpu: Double?
            if let elapsedTicks, let before = old[process.pid], before.started == process.started,
                process.ticks >= before.ticks
            {
                cpu = min(
                    Double(current.coreCount) * 100,
                    Double(process.ticks - before.ticks) / elapsedTicks * Double(current.coreCount) * 100)
            }
            return Self(
                pid: process.pid, started: process.started, name: process.name, cpu: cpu, memory: process.memory)
        }.sorted {
            if $0.cpu != $1.cpu { return ($0.cpu ?? -1) > ($1.cpu ?? -1) }
            if $0.memory != $1.memory { return ($0.memory ?? -1) > ($1.memory ?? -1) }
            return $0.pid < $1.pid
        }
    }
    public init(pid: Int, started: UInt64, name: String, cpu: Double? = nil, memory: Double? = nil) {
        self.pid = pid
        self.started = started
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }

}
