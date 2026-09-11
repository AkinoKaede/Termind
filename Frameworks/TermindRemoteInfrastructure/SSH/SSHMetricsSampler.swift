import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure

import struct TermindDomain.Host

public actor SSHMetricsSampler: MetricsSampling {
    private let session: any SSHExecSessionProtocol

    public init(session: any SSHExecSessionProtocol) { self.session = session }
    public func connect(_ configuration: SSHConnectionConfiguration) async throws {
        try await session.connect(using: configuration)
    }
    public func disconnect() async { await session.disconnect() }

    public func sample() async throws -> MetricsSample {
        let result = try await session.execute(
            Self.command, workingDirectory: nil, stdin: nil, timeout: 8,
            outputLimit: 262_144, onOutput: nil
        )
        guard result.exitCode != 42 else { throw MetricsReadError.unsupported }
        guard result.exitCode == 0, !result.stdoutTruncated else { throw MetricsReadError.output }
        let sample = LinuxMetricsParser.parse(result.stdout)
        guard sample.uptime != nil else { throw MetricsReadError.output }
        return sample
    }

    public func filesystems() async throws -> [MetricsFilesystem]? {
        let result = try await session.execute(
            "LC_ALL=C; export LC_ALL; cat /proc/self/mountinfo; printf '__TERMIND_DF__\\n'; df -PTkl 2>/dev/null || df -PTk",
            workingDirectory: nil, stdin: nil, timeout: 5, outputLimit: 524_288, onOutput: nil
        )
        guard result.exitCode == 0, !result.stdoutTruncated else { throw MetricsReadError.output }
        return try LinuxFilesystemParser.parse(result.stdout)
    }

    public func processes() async throws -> MetricsProcessSample? {
        let result = try await session.execute(
            Self.processCommand, workingDirectory: nil, stdin: nil, timeout: 5,
            outputLimit: 1_048_576, onOutput: nil
        )
        guard result.exitCode == 0, !result.stdoutTruncated else { throw MetricsReadError.output }
        return try LinuxProcessParser.parse(result.stdout)
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
        let result = try await session.execute(
            "command -v nvidia-smi >/dev/null 2>&1 || exit 42; LC_ALL=C nvidia-smi -q -x",
            workingDirectory: nil, stdin: nil, timeout: 5,
            outputLimit: NvidiaMetricsParser.maximumBytes, onOutput: nil
        )
        // NVIDIA exit code 6 means no device was found; other errors remain errors.
        if result.exitCode == 42 || result.exitCode == 6 { return nil }
        guard result.exitCode == 0, !result.stdoutTruncated else { throw MetricsReadError.output }
        return try NvidiaMetricsParser.parse(Data(result.stdout.utf8))
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
    public func makeMetricsSampler() -> any MetricsSampling { SSHMetricsSampler(session: makeExecSession()) }

    public func discoverMetricsHostKey(
        host: Host, proxy: SSHTransportProxy?, jumps: [SSHRouteHopConfiguration]
    ) async throws -> SSHHostKeyObservation {
        try await SSHSessionActor.discoverHostKey(
            hostID: host.id, host: host.host, port: host.port, proxy: proxy, jumps: jumps
        )
    }
}
