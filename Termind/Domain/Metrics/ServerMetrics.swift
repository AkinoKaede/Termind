import Foundation

nonisolated struct MetricsSelection: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var enabled = true
    /// nil selects all default devices; an empty set deliberately selects none.
    var disks: Set<String>?
    var interfaces: Set<String>?
}

nonisolated struct MetricsCounters: Equatable, Sendable {
    var read: UInt64
    var write: UInt64
    var readOperations: UInt64?
    var writeOperations: UInt64?
    var busyMilliseconds: UInt64?
    var readMilliseconds: UInt64?
    var writeMilliseconds: UInt64?
}

nonisolated struct MetricsSample: Sendable {
    var uptime: Double?
    var cpu: [UInt64]?
    var coreCount: Int?
    var load: [Double] = []
    var memoryFree: Double?
    var memoryCached: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var disks: [String: MetricsCounters]?
    var interfaces: [String: MetricsCounters]?
    var blocks: [String: MetricsCounters]?
    var interfaceKinds: [String: MetricsInterfaceKind] = [:]
    var interfaceAddresses: [String: [String]] = [:]
    var tcp: MetricsTCP?
}

nonisolated struct NvidiaGPU: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var utilization: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var memoryFree: Double?
    var memoryUtilization: Double?
    var encoder: Double?
    var decoder: Double?
    var fan: Double?
    var vbios: String?
    var memoryPercent: Double? {
        guard let memoryUsed, let memoryTotal, memoryTotal > 0 else { return nil }
        return min(100, max(0, memoryUsed / memoryTotal * 100))
    }
}

nonisolated struct NvidiaSnapshot: Sendable {
    var cudaVersion: String?
    var devices: [NvidiaGPU]
}

nonisolated enum MetricsGPUState: Equatable, Sendable {
    case probing, available, unavailable, failed
}

nonisolated struct MetricsDevicePoint: Identifiable, Sendable {
    var id: String
    var read: Double?
    var write: Double?
    var readTotal: Double
    var writeTotal: Double
    var readIOPS: Double?
    var writeIOPS: Double?
    var busy: Double?
    var readWait: Double?
    var writeWait: Double?
    var kind: MetricsInterfaceKind = .unknown
    var addresses: [String] = []
}

nonisolated struct MetricsPoint: Identifiable, Sendable {
    var id: Date { date }
    var date: Date
    var cpu: Double?
    var memory: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var networkReceive: Double?
    var networkSend: Double?
    var gpus: [NvidiaGPU] = []
    var uptime: Double?
    var coreCount: Int?
    var load: [Double] = []
    var cpuUser: Double?
    var cpuSystem: Double?
    var cpuWait: Double?
    var cpuSteal: Double?
    var cpuIdle: Double?
    var memoryFree: Double?
    var memoryCached: Double?
    var diskDevices: [MetricsDevicePoint] = []
    var networkDevices: [MetricsDevicePoint] = []
    var blockDevices: [String: MetricsDevicePoint] = [:]
    var networkSentTotal: Double?
    var networkReceivedTotal: Double?
    var tcp: MetricsTCP?
    var tcpRetransmissionPercent: Double?
}

nonisolated enum MetricsCalculation {
    static func point(
        previous: MetricsSample?, current: MetricsSample, selection: MetricsSelection, date: Date
    ) -> MetricsPoint {
        var point = MetricsPoint(date: date)
        point.uptime = current.uptime
        point.coreCount = current.coreCount
        point.load = current.load
        point.memoryFree = current.memoryFree
        point.memoryCached = current.memoryCached
        point.diskDevices = devices(nil, current.disks, selection.disks, elapsed: nil)
        point.networkDevices = networkDevices(nil, current, elapsed: nil)
        point.tcp = current.tcp
        let hardware = Set(current.interfaceKinds.filter { $0.value == .hardware }.keys)
        let aggregateInterfaces = selection.interfaces ?? (hardware.isEmpty ? nil : hardware)
        if let interfaces = current.interfaces {
            let names = aggregateInterfaces ?? Set(interfaces.keys)
            point.networkSentTotal = names.reduce(0) { $0 + Double(interfaces[$1]?.write ?? 0) }
            point.networkReceivedTotal = names.reduce(0) { $0 + Double(interfaces[$1]?.read ?? 0) }
        }
        point.blockDevices = Dictionary(
            uniqueKeysWithValues: devices(nil, current.blocks, nil, elapsed: nil).map { ($0.id, $0) })
        point.memoryUsed = current.memoryUsed
        point.memoryTotal = current.memoryTotal
        if let used = current.memoryUsed, let total = current.memoryTotal, total > 0 {
            point.memory = min(100, max(0, used / total * 100))
        }
        guard let previous, let before = previous.uptime, let after = current.uptime,
            after > before
        else { return point }
        let elapsed = after - before
        if let old = previous.cpu, let new = current.cpu, old.count >= 8, new.count >= 8,
            (0..<8).allSatisfy({ new[$0] >= old[$0] })
        {
            let delta = (0..<8).map { Double(new[$0] - old[$0]) }
            let total = delta.reduce(0, +)
            if total > 0 {
                point.cpu = max(0, min(100, (total - delta[3] - delta[4]) / total * 100))
                point.cpuUser = (delta[0] + delta[1]) / total * 100
                point.cpuSystem = (delta[2] + delta[5] + delta[6]) / total * 100
                point.cpuWait = delta[4] / total * 100
                point.cpuSteal = delta[7] / total * 100
                point.cpuIdle = delta[3] / total * 100
            }
        }
        point.diskDevices = devices(previous.disks, current.disks, selection.disks, elapsed: elapsed)
        point.networkDevices = networkDevices(previous, current, elapsed: elapsed)
        point.blockDevices = Dictionary(
            uniqueKeysWithValues: devices(previous.blocks, current.blocks, nil, elapsed: elapsed).map { ($0.id, $0) })
        if let oldSent = previous.tcp?.sent, let sent = current.tcp?.sent, sent > oldSent,
            let oldRetransmitted = previous.tcp?.retransmitted, let retransmitted = current.tcp?.retransmitted,
            retransmitted >= oldRetransmitted
        {
            point.tcpRetransmissionPercent = min(
                100, Double(retransmitted - oldRetransmitted) / Double(sent - oldSent) * 100)
        }
        let disk = rate(previous.disks, current.disks, selection.disks, elapsed)
        point.diskRead = disk?.0
        point.diskWrite = disk?.1
        let net = rate(previous.interfaces, current.interfaces, aggregateInterfaces, elapsed)
        point.networkReceive = net?.0
        point.networkSend = net?.1
        return point
    }

    private static func networkDevices(_ old: MetricsSample?, _ current: MetricsSample, elapsed: Double?)
        -> [MetricsDevicePoint]
    {
        devices(old?.interfaces, current.interfaces, nil, elapsed: elapsed).map { value in
            var result = value
            result.kind = current.interfaceKinds[value.id] ?? .unknown
            result.addresses = current.interfaceAddresses[value.id] ?? []
            return result
        }
    }

    private static func devices(
        _ old: [String: MetricsCounters]?, _ current: [String: MetricsCounters]?,
        _ selected: Set<String>?, elapsed: Double?
    ) -> [MetricsDevicePoint] {
        (current ?? [:]).keys.sorted().filter { selected?.contains($0) ?? true }.compactMap { name in
            guard let value = current?[name] else { return nil }
            let before = old?[name]
            func delta(_ oldValue: UInt64?, _ newValue: UInt64?) -> Double? {
                guard let oldValue, let newValue, newValue >= oldValue, let elapsed, elapsed > 0 else { return nil }
                return Double(newValue - oldValue) / elapsed
            }
            func wait(_ oldTime: UInt64?, _ newTime: UInt64?, _ oldCount: UInt64?, _ newCount: UInt64?) -> Double? {
                guard let oldTime, let newTime, newTime >= oldTime, let oldCount, let newCount, newCount > oldCount
                else { return nil }
                return Double(newTime - oldTime) / Double(newCount - oldCount)
            }
            return MetricsDevicePoint(
                id: name, read: delta(before?.read, value.read), write: delta(before?.write, value.write),
                readTotal: Double(value.read), writeTotal: Double(value.write),
                readIOPS: delta(before?.readOperations, value.readOperations),
                writeIOPS: delta(before?.writeOperations, value.writeOperations),
                busy: delta(before?.busyMilliseconds, value.busyMilliseconds).map { min(100, $0 / 10) },
                readWait: wait(
                    before?.readMilliseconds, value.readMilliseconds, before?.readOperations, value.readOperations),
                writeWait: wait(
                    before?.writeMilliseconds, value.writeMilliseconds, before?.writeOperations, value.writeOperations)
            )
        }
    }

    private static func rate(
        _ old: [String: MetricsCounters]?, _ new: [String: MetricsCounters]?,
        _ selected: Set<String>?, _ elapsed: Double
    ) -> (Double, Double)? {
        guard let old, let new else { return nil }
        let names = selected ?? Set(new.keys)
        guard !names.isEmpty else { return nil }
        var read = 0.0
        var write = 0.0
        for name in names {
            guard let before = old[name], let after = new[name],
                after.read >= before.read, after.write >= before.write
            else { return nil }
            read += Double(after.read - before.read) / elapsed
            write += Double(after.write - before.write) / elapsed
        }
        return (read, write)
    }
}
