import AgentKit
import Foundation

/// The wire projection stays with the tool; monitoring has no dependency on AgentKit.
nonisolated enum MetricsToolOutput {
    static func make(hostID: UUID, name: String, snapshot: MetricsSnapshot?, include: Set<String>) -> AgentJSONValue {
        var result: [String: AgentJSONValue] = [
            "host_id": .string(hostID.uuidString), "display_name": .string(name),
            "status": .string(snapshot?.state.rawValue ?? "not_monitored"),
        ]
        guard let snapshot else {
            result["overview"] = .null
            result["trend"] = .null
            for section in include {
                result[section] = .object([
                    "status": .string("unavailable"), "sampled_at": .null, "age_seconds": .null, "stale": .bool(false),
                ])
            }
            return .object(result)
        }
        let now = snapshot.capturedAt
        let point = snapshot.point
        var overview = metadata(date: point?.date, now: now)
        overview.merge(core(point)) { _, value in value }
        overview["load"] = .array((point?.load ?? []).map(number))
        overview["uptime_seconds"] = number(point?.uptime)
        overview["core_count"] = point?.coreCount.map { .number(Double($0)) } ?? .null
        overview["memory_used_bytes"] = number(point?.memoryUsed)
        overview["memory_total_bytes"] = number(point?.memoryTotal)
        overview["memory_free_bytes"] = number(point?.memoryFree)
        overview["memory_cached_bytes"] = number(point?.memoryCached)
        for (key, value) in [
            ("cpu_user_percent", point?.cpuUser), ("cpu_system_percent", point?.cpuSystem),
            ("cpu_wait_percent", point?.cpuWait), ("cpu_steal_percent", point?.cpuSteal),
            ("cpu_idle_percent", point?.cpuIdle),
        ] { overview[key] = number(value) }
        result["overview"] = .object(overview)
        result["trend"] = trend(snapshot.history, now: now)
        if include.contains("devices") {
            var devices = metadata(date: point?.date, now: now)
            devices["disks"] = .array((point?.diskDevices ?? []).map { device($0, network: false) })
            devices["interfaces"] = .array((point?.networkDevices ?? []).map { device($0, network: true) })
            result["devices"] = .object(devices)
        }
        if include.contains("gpu") {
            var gpu = metadata(date: snapshot.gpuDate, now: now, failed: snapshot.gpuState == .failed)
            if snapshot.gpuState == .unavailable { gpu["status"] = .string("unavailable") }
            if snapshot.gpuState == .probing { gpu["status"] = .string("probing") }
            gpu["cuda_version"] = snapshot.gpu?.cudaVersion.map(AgentJSONValue.string) ?? .null
            gpu["devices"] = .array(
                (snapshot.gpu?.devices ?? []).map { value in
                    .object([
                        "id": .string(value.id), "name": .string(value.name),
                        "utilization_percent": number(value.utilization), "memory_used_bytes": number(value.memoryUsed),
                        "memory_total_bytes": number(value.memoryTotal), "memory_free_bytes": number(value.memoryFree),
                        "memory_utilization_percent": number(value.memoryUtilization),
                        "encoder_percent": number(value.encoder), "decoder_percent": number(value.decoder),
                        "fan_percent": number(value.fan), "vbios": value.vbios.map(AgentJSONValue.string) ?? .null,
                    ])
                })
            result["gpu"] = .object(gpu)
        }
        if include.contains("processes") {
            var processes = metadata(date: snapshot.processesDate, now: now, failed: snapshot.processesFailed)
            processes["total_count"] = .number(Double(snapshot.processes.count))
            processes["truncated"] = .bool(snapshot.processes.count > 20)
            processes["items"] = .array(
                snapshot.processes.prefix(20).map { value in
                    .object([
                        "id": .string(value.id), "pid": .number(Double(value.pid)), "name": .string(value.name),
                        "cpu_percent": number(value.cpu), "memory_bytes": number(value.memory),
                    ])
                })
            result["processes"] = .object(processes)
        }
        if include.contains("filesystems") {
            var filesystems = metadata(
                date: snapshot.filesystemsDate, now: now, limit: 60, failed: snapshot.filesystemsFailed)
            filesystems["items"] = .array(
                snapshot.filesystems.map { value in
                    .object([
                        "mount_point": .string(value.mountPoint), "device": .string(value.device),
                        "type": .string(value.type), "block_id": .string(value.blockID),
                        "used_bytes": number(value.used), "total_bytes": number(value.total),
                        "used_percent": number(value.usedPercent),
                    ])
                })
            result["filesystems"] = .object(filesystems)
        }
        return .object(result)
    }

    private static func number(_ value: Double?) -> AgentJSONValue {
        guard let value, value.isFinite else { return .null }
        return .number(value)
    }

    private static func date(_ value: Date?) -> AgentJSONValue {
        value.map { .string($0.ISO8601Format()) } ?? .null
    }

    private static func metadata(date sampledAt: Date?, now: Date, limit: Double = 30, failed: Bool = false)
        -> [String: AgentJSONValue]
    {
        let age = sampledAt.map { max(0, now.timeIntervalSince($0)) }
        let stale = age.map { $0 > limit } ?? false
        return [
            "sampled_at": date(sampledAt), "age_seconds": number(age), "stale": .bool(stale),
            "status": .string(failed ? "failed" : sampledAt == nil ? "unavailable" : stale ? "stale" : "available"),
        ]
    }

    private static func core(_ point: MetricsPoint?) -> [String: AgentJSONValue] {
        [
            "cpu_percent": number(point?.cpu), "memory_percent": number(point?.memory),
            "disk_read_bytes_per_second": number(point?.diskRead),
            "disk_write_bytes_per_second": number(point?.diskWrite),
            "network_receive_bytes_per_second": number(point?.networkReceive),
            "network_send_bytes_per_second": number(point?.networkSend),
        ]
    }

    private static func trend(_ history: [MetricsPoint], now: Date) -> AgentJSONValue {
        let points = history.filter { $0.date >= now.addingTimeInterval(-300) && $0.date <= now }.sorted {
            $0.date < $1.date
        }
        var fields: [String: AgentJSONValue] = [
            "from": date(points.first?.date), "to": date(points.last?.date),
            "sample_count": .number(Double(points.count)),
        ]
        let values = points.map { core($0) }
        for key in core(nil).keys {
            let samples = values.compactMap { $0[key]?.numberValue }
            fields[key] = .object([
                "mean": samples.isEmpty ? .null : number(samples.reduce(0, +) / Double(samples.count)),
                "peak": number(samples.max()), "sample_count": .number(Double(samples.count)),
            ])
        }
        return .object(fields)
    }

    private static func device(_ value: MetricsDevicePoint, network: Bool) -> AgentJSONValue {
        var result: [String: AgentJSONValue] = [
            "id": .string(value.id),
            network ? "receive_bytes_per_second" : "read_bytes_per_second": number(value.read),
            network ? "send_bytes_per_second" : "write_bytes_per_second": number(value.write),
            network ? "received_bytes" : "read_bytes": number(value.readTotal),
            network ? "sent_bytes" : "written_bytes": number(value.writeTotal),
        ]
        if network {
            result["kind"] = .string(value.kind.rawValue)
            result["addresses"] = .array(value.addresses.map(AgentJSONValue.string))
        } else {
            result["read_iops"] = number(value.readIOPS)
            result["write_iops"] = number(value.writeIOPS)
            result["busy_percent"] = number(value.busy)
            result["read_wait_milliseconds"] = number(value.readWait)
            result["write_wait_milliseconds"] = number(value.writeWait)
        }
        return .object(result)
    }
}
