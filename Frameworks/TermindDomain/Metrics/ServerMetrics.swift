import Foundation

public nonisolated struct MetricsSelection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var tailscaleGroupID: UUID?
    public var displayName: String?
    public var enabled = true
    /// nil selects all default devices; an empty set deliberately selects none.
    public var disks: Set<String>?
    public var interfaces: Set<String>?
    public init(id: UUID, enabled: Bool = true, disks: Set<String>? = nil, interfaces: Set<String>? = nil) {
        self.id = id
        self.enabled = enabled
        self.disks = disks
        self.interfaces = interfaces
    }

}

public nonisolated struct MetricsCounters: Equatable, Sendable {
    public var read: UInt64
    public var write: UInt64
    public var readOperations: UInt64?
    public var writeOperations: UInt64?
    public var busyMilliseconds: UInt64?
    public var readMilliseconds: UInt64?
    public var writeMilliseconds: UInt64?
    public init(
        read: UInt64, write: UInt64, readOperations: UInt64? = nil, writeOperations: UInt64? = nil,
        busyMilliseconds: UInt64? = nil, readMilliseconds: UInt64? = nil, writeMilliseconds: UInt64? = nil
    ) {
        self.read = read
        self.write = write
        self.readOperations = readOperations
        self.writeOperations = writeOperations
        self.busyMilliseconds = busyMilliseconds
        self.readMilliseconds = readMilliseconds
        self.writeMilliseconds = writeMilliseconds
    }

}

public nonisolated struct MetricsSample: Sendable {
    public var uptime: Double?
    public var cpu: [UInt64]?
    /// Linux logical CPU IDs and counters. Empty counters retain an unreadable CPU's identity.
    public var cpuCores: [Int: [UInt64]]
    public var coreCount: Int?
    public var load: [Double] = []
    public var memoryFree: Double?
    public var memoryCached: Double?
    public var memoryUsed: Double?
    public var memoryTotal: Double?
    public var swapFree: Double?
    public var swapTotal: Double?
    public var disks: [String: MetricsCounters]?
    public var interfaces: [String: MetricsCounters]?
    public var blocks: [String: MetricsCounters]?
    public var interfaceKinds: [String: MetricsInterfaceKind] = [:]
    public var interfaceAddresses: [String: [String]] = [:]
    public var tcp: MetricsTCP?
    public init(
        uptime: Double? = nil, cpu: [UInt64]? = nil, cpuCores: [Int: [UInt64]] = [:],
        coreCount: Int? = nil, load: [Double] = [],
        memoryFree: Double? = nil, memoryCached: Double? = nil, memoryUsed: Double? = nil, memoryTotal: Double? = nil,
        swapFree: Double? = nil, swapTotal: Double? = nil,
        disks: [String: MetricsCounters]? = nil, interfaces: [String: MetricsCounters]? = nil,
        blocks: [String: MetricsCounters]? = nil, interfaceKinds: [String: MetricsInterfaceKind] = [:],
        interfaceAddresses: [String: [String]] = [:], tcp: MetricsTCP? = nil
    ) {
        self.uptime = uptime
        self.cpu = cpu
        self.cpuCores = cpuCores
        self.coreCount = coreCount
        self.load = load
        self.memoryFree = memoryFree
        self.memoryCached = memoryCached
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.swapFree = swapFree
        self.swapTotal = swapTotal
        self.disks = disks
        self.interfaces = interfaces
        self.blocks = blocks
        self.interfaceKinds = interfaceKinds
        self.interfaceAddresses = interfaceAddresses
        self.tcp = tcp
    }

}

public nonisolated struct NvidiaGPU: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var utilization: Double?
    public var memoryUsed: Double?
    public var memoryTotal: Double?
    public var memoryFree: Double?
    public var memoryUtilization: Double?
    public var encoder: Double?
    public var decoder: Double?
    public var fan: Double?
    public var vbios: String?
    public var memoryPercent: Double? {
        guard let memoryUsed, let memoryTotal, memoryTotal > 0 else { return nil }
        return min(100, max(0, memoryUsed / memoryTotal * 100))
    }
    public init(
        id: String, name: String, utilization: Double? = nil, memoryUsed: Double? = nil, memoryTotal: Double? = nil,
        memoryFree: Double? = nil, memoryUtilization: Double? = nil, encoder: Double? = nil, decoder: Double? = nil,
        fan: Double? = nil, vbios: String? = nil
    ) {
        self.id = id
        self.name = name
        self.utilization = utilization
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryFree = memoryFree
        self.memoryUtilization = memoryUtilization
        self.encoder = encoder
        self.decoder = decoder
        self.fan = fan
        self.vbios = vbios
    }

}

public nonisolated struct NvidiaSnapshot: Sendable {
    public var cudaVersion: String?
    public var devices: [NvidiaGPU]
    public init(cudaVersion: String? = nil, devices: [NvidiaGPU]) {
        self.cudaVersion = cudaVersion
        self.devices = devices
    }

}

public nonisolated enum MetricsGPUState: Equatable, Sendable {
    case probing, available, unavailable, failed
}

public nonisolated struct MetricsDevicePoint: Identifiable, Sendable {
    public var id: String
    public var read: Double?
    public var write: Double?
    public var readTotal: Double
    public var writeTotal: Double
    public var readIOPS: Double?
    public var writeIOPS: Double?
    public var busy: Double?
    public var readWait: Double?
    public var writeWait: Double?
    public var kind: MetricsInterfaceKind = .unknown
    public var addresses: [String] = []
    public init(
        id: String, read: Double? = nil, write: Double? = nil, readTotal: Double, writeTotal: Double,
        readIOPS: Double? = nil, writeIOPS: Double? = nil, busy: Double? = nil, readWait: Double? = nil,
        writeWait: Double? = nil, kind: MetricsInterfaceKind = .unknown, addresses: [String] = []
    ) {
        self.id = id
        self.read = read
        self.write = write
        self.readTotal = readTotal
        self.writeTotal = writeTotal
        self.readIOPS = readIOPS
        self.writeIOPS = writeIOPS
        self.busy = busy
        self.readWait = readWait
        self.writeWait = writeWait
        self.kind = kind
        self.addresses = addresses
    }

}

public nonisolated struct MetricsPoint: Identifiable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var cpuUsage: MetricsCPUUsage
    public var cpu: Double? {
        get { cpuUsage.utilization }
        set { cpuUsage.utilization = newValue }
    }
    public var memory: Double?
    public var memoryUsed: Double?
    public var memoryTotal: Double?
    public var swapPercent: Double?
    public var swapUsed: Double?
    public var swapTotal: Double?
    public var swapFree: Double?
    public var diskRead: Double?
    public var diskWrite: Double?
    public var networkReceive: Double?
    public var networkSend: Double?
    public var gpus: [NvidiaGPU] = []
    public var uptime: Double?
    public var coreCount: Int?
    public var load: [Double] = []
    public var cpuCores: [MetricsCPUPoint]
    public var memoryFree: Double?
    public var memoryCached: Double?
    public var diskDevices: [MetricsDevicePoint] = []
    public var networkDevices: [MetricsDevicePoint] = []
    public var blockDevices: [String: MetricsDevicePoint] = [:]
    public var networkSentTotal: Double?
    public var networkReceivedTotal: Double?
    public var tcp: MetricsTCP?
    public var tcpRetransmissionPercent: Double?
    public init(
        date: Date, cpu: Double? = nil, memory: Double? = nil, memoryUsed: Double? = nil, memoryTotal: Double? = nil,
        swapPercent: Double? = nil, swapUsed: Double? = nil, swapTotal: Double? = nil, swapFree: Double? = nil,
        diskRead: Double? = nil, diskWrite: Double? = nil, networkReceive: Double? = nil, networkSend: Double? = nil,
        gpus: [NvidiaGPU] = [], uptime: Double? = nil, coreCount: Int? = nil, load: [Double] = [],
        cpuCores: [MetricsCPUPoint] = [], memoryFree: Double? = nil,
        memoryCached: Double? = nil,
        diskDevices: [MetricsDevicePoint] = [], networkDevices: [MetricsDevicePoint] = [],
        blockDevices: [String: MetricsDevicePoint] = [:], networkSentTotal: Double? = nil,
        networkReceivedTotal: Double? = nil, tcp: MetricsTCP? = nil, tcpRetransmissionPercent: Double? = nil
    ) {
        self.date = date
        cpuUsage = MetricsCPUUsage(utilization: cpu)
        self.memory = memory
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.swapPercent = swapPercent
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.swapFree = swapFree
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.networkReceive = networkReceive
        self.networkSend = networkSend
        self.gpus = gpus
        self.uptime = uptime
        self.coreCount = coreCount
        self.load = load
        self.cpuCores = cpuCores
        self.memoryFree = memoryFree
        self.memoryCached = memoryCached
        self.diskDevices = diskDevices
        self.networkDevices = networkDevices
        self.blockDevices = blockDevices
        self.networkSentTotal = networkSentTotal
        self.networkReceivedTotal = networkReceivedTotal
        self.tcp = tcp
        self.tcpRetransmissionPercent = tcpRetransmissionPercent
    }

}

public nonisolated enum MetricsCalculation {
    public static func point(
        previous: MetricsSample?, current: MetricsSample, selection: MetricsSelection, date: Date
    ) -> MetricsPoint {
        var point = MetricsPoint(date: date)
        point.uptime = current.uptime
        point.coreCount = current.coreCount
        point.cpuCores = current.cpuCores.keys.sorted().map { MetricsCPUPoint(id: $0) }
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
        point.swapFree = current.swapFree
        point.swapTotal = current.swapTotal
        if let free = current.swapFree, let total = current.swapTotal {
            let used = min(total, max(0, total - free))
            point.swapUsed = used
            if total > 0 { point.swapPercent = min(100, max(0, used / total * 100)) }
        }
        guard let previous, let before = previous.uptime, let after = current.uptime,
            after > before
        else { return point }
        let elapsed = after - before
        point.cpuUsage = cpuUsage(previous: previous.cpu, current: current.cpu)
        point.cpuCores = current.cpuCores.keys.sorted().map {
            MetricsCPUPoint(id: $0, usage: cpuUsage(previous: previous.cpuCores[$0], current: current.cpuCores[$0]))
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

    private static func cpuUsage(previous: [UInt64]?, current: [UInt64]?) -> MetricsCPUUsage {
        guard let old = previous, let new = current, old.count >= 8, new.count >= 8,
            (0..<8).allSatisfy({ new[$0] >= old[$0] })
        else { return MetricsCPUUsage() }
        // Guest counters are already included in user/nice time.
        let delta = (0..<8).map { Double(new[$0] - old[$0]) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return MetricsCPUUsage() }
        return MetricsCPUUsage(
            utilization: max(0, min(100, (total - delta[3] - delta[4]) / total * 100)),
            user: (delta[0] + delta[1]) / total * 100, system: (delta[2] + delta[5] + delta[6]) / total * 100,
            wait: delta[4] / total * 100, steal: delta[7] / total * 100, idle: delta[3] / total * 100)
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
