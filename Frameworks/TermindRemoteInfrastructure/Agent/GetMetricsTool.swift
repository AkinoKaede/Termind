import AgentKit
import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

nonisolated public struct GetMetricsTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(id: "builtin.get_metrics", present: present)
    public static let sections: Set<String> = ["devices", "gpu", "processes", "filesystems"]
    public let hosts: AgentHostResolver
    public let metrics: any MetricsSnapshotReading

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "get_metrics",
            "Read cached Termind host metrics and a five-minute trend summary without connecting or sampling. "
                + "Use list_hosts for host_id. Optional details may be missing or stale; no data is refreshed. "
                + "Times are UTC ISO 8601, sizes are bytes, rates are bytes/second, utilization is percent. "
                + "Process CPU is 100% per logical core; only the top 20 cached processes are returned.",
            properties: [
                "host_id": Self.string(),
                "include": Self.array(
                    items: .object([
                        "type": .string("string"),
                        "enum": .array(Self.sections.sorted().map(AgentJSONValue.string)),
                    ]), max: 4),
            ], required: ["host_id"], target: .host, safety: .locallyReadOnly, concurrency: .parallel,
            presentation: .init(
                symbol: "gauge.with.dots.needle.67percent", activity: .semanticLabel(.metrics),
                output: .json, actionKind: .read
            )
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var checked = invocation
        let arguments = try Arguments(invocation)
        checked.targetHostID = try arguments.uuid("host_id")
        _ = try Self.includes(arguments)
        return AgentToolPreflight(invocation: checked, safety: .locallyReadOnly)
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let hostID = try arguments.uuid("host_id")
        let includes = try Self.includes(arguments)
        guard let host = await hosts.listing().hosts.first(where: { $0.id == hostID }) else {
            throw AgentToolError.invalidHost
        }
        let snapshot = await metrics.snapshot(for: hostID)
        return Self.result(
            invocation,
            MetricsToolOutput.make(hostID: hostID, name: host.displayName, snapshot: snapshot, include: includes)
        )
    }

    private static func includes(_ arguments: Arguments) throws -> Set<String> {
        guard let value = arguments.object["include"] else { return [] }
        guard let array = value.arrayValue, array.count <= 4,
            array.allSatisfy({ $0.stringValue.map(sections.contains) == true })
        else {
            throw AgentToolError.invalidArguments("include must contain only devices, gpu, processes, or filesystems.")
        }
        return Set(array.compactMap(\.stringValue))
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        guard let object = input.result.objectValue else {
            return [.message(input.result.encodedString, .secondary)]
        }
        func field(_ key: String.LocalizationValue, _ value: String) -> AgentToolDetail.Item {
            .field(.init(label: AppLocalization.string(key, locale: input.locale), value: value))
        }
        var items = [field("Host", object["display_name"]?.stringValue ?? "—")]
        let state = object["status"]?.stringValue ?? "not_monitored"
        let stateKey: String.LocalizationValue =
            switch state {
            case "live": "Live"
            case "paused": "Paused"
            case "sleeping": "Sleeping"
            case "stopped": "Stopped"
            case "connecting": "Connecting…"
            case "collecting": "Connected — collecting metrics…"
            case "awaiting_authentication": "Authentication required"
            case "failed": "Metrics collection failed"
            default: "Not monitored"
            }
        items.append(field("Status", AppLocalization.string(stateKey, locale: input.locale)))
        if let overview = object["overview"]?.objectValue {
            if let date = overview["sampled_at"]?.stringValue { items.append(field("Sampled at", date)) }
            for (key, label) in [("cpu_percent", "CPU"), ("memory_percent", "Memory")] {
                let value = overview[key]?.numberValue.map { String(format: "%.1f%%", $0) } ?? "—"
                items.append(field(String.LocalizationValue(label), value))
            }
            if let total = overview["swap_total_bytes"]?.numberValue, total > 0 {
                let value = overview["swap_percent"]?.numberValue.map { String(format: "%.1f%%", $0) } ?? "—"
                items.append(field("Swap", value))
            }
            if overview["stale"]?.boolValue == true {
                items.append(
                    .message(AppLocalization.string("Cached metrics are stale", locale: input.locale), .warning))
            }
        }
        return items
    }

    public init(hosts: AgentHostResolver, metrics: any MetricsSnapshotReading) {
        self.hosts = hosts
        self.metrics = metrics
    }
}
