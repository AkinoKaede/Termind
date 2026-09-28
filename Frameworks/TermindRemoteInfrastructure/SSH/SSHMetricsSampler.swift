import Foundation
import Logging
import TermindApplication
import TermindDomain
import TermindInfrastructure

import struct TermindDomain.Host

public actor SSHMetricsSampler: MetricsSampling {
    private enum MetricsFrameFailure {
        case missing, oversized
    }

    private struct MetricsCommandResult {
        var raw: SSHExecResult
        var payload: String?
        var frameFailure: MetricsFrameFailure?
    }

    private let adapter: SSHExclusiveConnectionAdapter<any SSHConnectionProtocol>
    private let logger: Logger
    private var hostID: UUID?

    public init(
        connection: any SSHConnectionProtocol,
        hostID: UUID? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.metrics")
    ) {
        adapter = SSHExclusiveConnectionAdapter(connection: connection) { await $0.disconnect() }
        self.hostID = hostID
        self.logger = logger
    }
    public func connect(_ configuration: SSHConnectionConfiguration) async throws {
        try await connect(SSHConnectionRequest(configuration: configuration))
    }
    public func connect(_ request: SSHConnectionRequest) async throws {
        var request = request
        request.permitsAgentForwarding = false
        hostID = request.configuration.hostID
        let isolated = request
        try await adapter.withConnection { try await $0.connect(using: isolated) }
    }
    public func disconnect() async { await adapter.disconnect() }

    public func sample() async throws -> MetricsSample {
        let result = try await execute(
            Self.command, workingDirectory: nil, stdin: nil, timeout: 8,
            outputLimit: 262_144, onOutput: nil
        )
        var metadata = primarySampleMetadata(result.raw.stdout, components: result.payload)
        metadata["outcome"] = "collected"
        logger.info("metrics.sample.collected", metadata: metadata)
        guard result.raw.exitCode != 42 else { throw MetricsReadError.unsupported }
        guard result.raw.exitCode == 0, !result.raw.stdoutTruncated else {
            if result.raw.stdoutTruncated {
                logInvalidPrimarySample(result.raw.stdout, event: "metrics.sample.oversized")
            }
            throw MetricsReadError.output
        }
        guard let payload = result.payload else {
            let event: Logger.Message =
                result.frameFailure == .oversized ? "metrics.sample.oversized" : "metrics.sample.incomplete"
            logInvalidPrimarySample(result.raw.stdout, event: event)
            throw MetricsReadError.output
        }
        let sample = LinuxMetricsParser.parse(payload)
        guard sample.uptime != nil else {
            logInvalidPrimarySample(result.raw.stdout, event: "metrics.sample.incomplete", components: payload)
            throw MetricsReadError.output
        }
        return sample
    }

    public func filesystems() async throws -> [MetricsFilesystem]? {
        let result = try await execute(
            "LC_ALL=C; export LC_ALL; cat /proc/self/mountinfo; printf '__TERMIND_DF__\\n'; df -PTkl 2>/dev/null || df -PTk",
            workingDirectory: nil, stdin: nil, timeout: 5, outputLimit: 524_288, onOutput: nil
        )
        guard result.raw.exitCode == 0, !result.raw.stdoutTruncated, let payload = result.payload else {
            throw MetricsReadError.output
        }
        return try LinuxFilesystemParser.parse(payload)
    }

    public func processes() async throws -> MetricsProcessSample? {
        let result = try await execute(
            Self.processCommand, workingDirectory: nil, stdin: nil, timeout: 5,
            outputLimit: 1_048_576, onOutput: nil
        )
        guard result.raw.exitCode == 0, !result.raw.stdoutTruncated, let payload = result.payload else {
            throw MetricsReadError.output
        }
        return try LinuxProcessParser.parse(payload)
    }

    private static let processCommand = """
        export LC_ALL=C
        cat /proc/stat || exit 1
        printf 'pagesize '; getconf PAGESIZE 2>/dev/null || printf '\n'
        printf '__TERMIND_PROCESSES__\n'
        for f in /proc/[0-9]*/stat; do
            if IFS= read -r line < "$f" 2>/dev/null; then printf '%s\n' "$line"; fi
        done
        exit 0
        """

    public func gpu() async throws -> NvidiaSnapshot? {
        let result = try await execute(
            "command -v nvidia-smi >/dev/null 2>&1 || exit 42; LC_ALL=C nvidia-smi -q -x",
            workingDirectory: nil, stdin: nil, timeout: 5,
            outputLimit: NvidiaMetricsParser.maximumBytes, onOutput: nil
        )
        // NVIDIA exit code 6 means no device was found; other errors remain errors.
        if result.raw.exitCode == 42 || result.raw.exitCode == 6 { return nil }
        guard result.raw.exitCode == 0, !result.raw.stdoutTruncated, let payload = result.payload else {
            throw MetricsReadError.output
        }
        return try NvidiaMetricsParser.parse(Data(payload.utf8))
    }

    private static let command = """
        export LC_ALL=C
        [ -r /proc/uptime ] && [ -r /proc/stat ] || exit 42
        printf '__TERMIND_UPTIME__\\n'; cat /proc/uptime
        printf '__TERMIND_CPU__\\n'; cat /proc/stat
        printf '__TERMIND_LOAD__\\n'; cat /proc/loadavg 2>/dev/null
        printf '__TERMIND_MEMORY__\\n'; cat /proc/meminfo 2>/dev/null
        printf '__TERMIND_DISKS__\\n'
        while read -r major minor name stats; do
            case "$name" in loop*|ram*|zram*) continue;; esac
            [ -d "/sys/block/$name" ] || continue
            set -- /sys/block/"$name"/slaves/*
            [ -e "$1" ] && continue
            printf '%s %s\\n' "$name" "$stats"
        done < /proc/diskstats
        printf '__TERMIND_BLOCKS__\\n'
        while read -r major minor name stats; do
            printf '%s:%s %s %s\\n' "$major" "$minor" "$name" "$stats"
        done < /proc/diskstats
        printf '__TERMIND_NETWORK__\\n'; cat /proc/net/dev 2>/dev/null
        printf '__TERMIND_INTERFACES__\\n'
        for i in /sys/class/net/*; do
            [ -e "$i" ] || continue
            kind=virtual; [ -e "$i/device" ] && kind=hardware
            printf '%s %s\\n' "${i##*/}" "$kind"
        done
        printf '__TERMIND_ADDRESSES__\\n'; ip -o addr show 2>/dev/null
        printf '__TERMIND_TCP__\\n'; cat /proc/net/snmp 2>/dev/null
        exit 0
        """

    private func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> MetricsCommandResult {
        // A remote login shell may emit OSC frames or banners before this command and exit hooks may emit more
        // afterward. Keep that transport output available for diagnostics, but parse only our structured frame.
        let framedCommand = """
            printf '\(Self.frameBegin)\\n'
            (
            \(command)
            )
            __termind_metrics_status=$?
            printf '\\n\(Self.frameEnd)\\n'
            exit "$__termind_metrics_status"
            """
        let transportLimit = outputLimit.addingReportingOverflow(Self.framingAllowance)
        let raw = try await adapter.withConnection { connection in
            try await connection.execute(
                framedCommand, workingDirectory: workingDirectory,
                stdin: stdin.map(SSHCommandInput.plain),
                timeout: timeout, outputLimit: transportLimit.overflow ? outputLimit : transportLimit.partialValue,
                onOutput: onOutput)
        }
        guard !raw.stdoutTruncated else {
            return MetricsCommandResult(raw: raw, payload: nil, frameFailure: nil)
        }
        guard let payload = Self.framedPayload(in: raw.stdout) else {
            return MetricsCommandResult(raw: raw, payload: nil, frameFailure: .missing)
        }
        guard payload.utf8.count <= outputLimit else {
            return MetricsCommandResult(raw: raw, payload: nil, frameFailure: .oversized)
        }
        return MetricsCommandResult(raw: raw, payload: payload, frameFailure: nil)
    }

    private func logInvalidPrimarySample(
        _ payload: String, event: Logger.Message, components: String? = nil
    ) {
        let sanitized = Self.redactingAddresses(in: payload)
        var metadata = primarySampleMetadata(payload, components: components)
        metadata["metrics_payload"] = "\(sanitized)"
        metadata["metrics_payload_truncated"] = "\(payload.utf8.count > 8 * 1_024)"
        metadata["outcome"] = "failure"
        logger.error(event, metadata: metadata)
    }

    private func primarySampleMetadata(_ payload: String, components: String? = nil) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "metrics_payload_bytes": "\(payload.utf8.count)",
            "protocol": "ssh",
            "stage": "metrics_collection",
        ]
        if let hostID { metadata["host_id"] = "\(hostID.uuidString.lowercased())" }
        for (key, byteCount) in Self.componentByteCounts(in: components ?? payload) {
            metadata[key] = "\(byteCount)"
        }
        return metadata
    }

    private static let frameBegin = "__TERMIND_METRICS_BEGIN__"
    private static let frameEnd = "__TERMIND_METRICS_END__"
    private static let framingAllowance = 8 * 1_024

    private static func framedPayload(in output: String) -> String? {
        guard let begin = output.range(of: frameBegin),
            let end = output.range(of: frameEnd, options: .backwards),
            begin.upperBound <= end.lowerBound
        else { return nil }
        var lowerBound = begin.upperBound
        if lowerBound < end.lowerBound, output[lowerBound] == "\n" {
            lowerBound = output.index(after: lowerBound)
        }
        var upperBound = end.lowerBound
        if lowerBound < upperBound {
            let previous = output.index(before: upperBound)
            if output[previous] == "\n" { upperBound = previous }
        }
        return String(output[lowerBound..<upperBound])
    }

    private static let componentMarkers: [(marker: String, metadataKey: String)] = [
        ("__TERMIND_UPTIME__", "metrics_uptime_bytes"),
        ("__TERMIND_CPU__", "metrics_cpu_bytes"),
        ("__TERMIND_LOAD__", "metrics_load_bytes"),
        ("__TERMIND_MEMORY__", "metrics_memory_bytes"),
        ("__TERMIND_DISKS__", "metrics_disks_bytes"),
        ("__TERMIND_BLOCKS__", "metrics_blocks_bytes"),
        ("__TERMIND_NETWORK__", "metrics_network_bytes"),
        ("__TERMIND_INTERFACES__", "metrics_interfaces_bytes"),
        ("__TERMIND_ADDRESSES__", "metrics_addresses_bytes"),
        ("__TERMIND_TCP__", "metrics_tcp_bytes"),
    ]

    private static func componentByteCounts(in payload: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, component) in componentMarkers.enumerated() {
            guard let markerRange = payload.range(of: component.marker) else {
                result[component.metadataKey] = 0
                continue
            }
            var contentStart = markerRange.upperBound
            if contentStart < payload.endIndex, payload[contentStart] == "\n" {
                contentStart = payload.index(after: contentStart)
            }
            var contentEnd = payload.endIndex
            for nextComponent in componentMarkers.dropFirst(index + 1) {
                if let next = payload[contentStart...].range(of: nextComponent.marker) {
                    contentEnd = next.lowerBound
                    break
                }
            }
            result[component.metadataKey] = payload[contentStart..<contentEnd].utf8.count
        }
        return result
    }

    private static func redactingAddresses(in payload: String) -> String {
        guard let start = payload.range(of: "__TERMIND_ADDRESSES__") else { return payload }
        let suffix = payload[start.upperBound...]
        guard let end = suffix.range(of: "__TERMIND_TCP__") else {
            return String(payload[..<start.lowerBound]) + "__TERMIND_ADDRESSES__\n[redacted]\n"
        }
        return String(payload[..<start.lowerBound]) + "__TERMIND_ADDRESSES__\n[redacted]\n"
            + String(suffix[end.lowerBound...])
    }
}

public final class MetricsPreferences: MetricsConfigurationStoring {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> [MetricsSelection] {
        guard let data = defaults.data(forKey: "metrics.servers") else { return [] }
        return (try? JSONDecoder().decode([MetricsSelection].self, from: data)) ?? []
    }
    public func save(_ selections: [MetricsSelection]) {
        guard let data = try? JSONEncoder().encode(selections) else { return }
        defaults.set(data, forKey: "metrics.servers")
    }
}

nonisolated extension RemoteConnectionCoordinator {
    public func makeMetricsSampler() -> any MetricsSampling {
        SSHMetricsSampler(connection: makeConnection(), logger: logger)
    }

}
