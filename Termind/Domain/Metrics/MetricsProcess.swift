import Foundation

nonisolated struct MetricsProcessCounter: Sendable {
    var pid: Int
    var name: String
    var ticks: UInt64
    var started: UInt64
    var memory: Double?
}

nonisolated struct MetricsProcessSample: Sendable {
    var cpu: [UInt64]
    var coreCount: Int
    var processes: [MetricsProcessCounter]
}

nonisolated struct MetricsProcess: Identifiable, Sendable {
    var id: String { "\(pid):\(started)" }
    var pid: Int
    var started: UInt64
    var name: String
    var cpu: Double?
    var memory: Double?
    var cpuSortValue: Double { cpu ?? -1 }
    var memorySortValue: Double { memory ?? -1 }

    static func rows(previous: MetricsProcessSample?, current: MetricsProcessSample) -> [Self] {
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
}
