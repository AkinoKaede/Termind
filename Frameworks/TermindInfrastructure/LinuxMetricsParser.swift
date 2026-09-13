import Foundation
import TermindDomain

/// Parses bounded, section-framed output. A missing section stays unknown.
public nonisolated enum LinuxMetricsParser {
    public static func parse(_ text: String) -> MetricsSample {
        var sections: [String: String] = [:]
        var key: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("__TERMIND_"), line.hasSuffix("__") {
                key = String(line)
                sections[key!] = ""
            } else if let key {
                sections[key, default: ""] += line + "\n"
            }
        }
        var sample = MetricsSample()
        sample.uptime = sections["__TERMIND_UPTIME__"]?.split(whereSeparator: \.isWhitespace).first
            .flatMap { Double($0) }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let cpu = sections["__TERMIND_CPU__"]?.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) {
            let fields = cpu.split(whereSeparator: \.isWhitespace).dropFirst()
            let values = fields.compactMap { UInt64($0) }
            if values.count == fields.count, values.count >= 8 { sample.cpu = values }
        }
        if let cpuSection = sections["__TERMIND_CPU__"] {
            let count = cpuSection.split(separator: "\n").filter {
                guard let name = $0.split(whereSeparator: \.isWhitespace).first else { return false }
                return name.hasPrefix("cpu") && Int(name.dropFirst(3)) != nil
            }.count
            sample.coreCount = count > 0 ? count : nil
        }
        sample.load =
            sections["__TERMIND_LOAD__"]?.split(whereSeparator: \.isWhitespace).prefix(3)
            .compactMap { Double($0) }.filter { $0.isFinite && $0 >= 0 } ?? []
        if let memory = sections["__TERMIND_MEMORY__"] {
            var values: [String: Double] = [:]
            for line in memory.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count >= 3, fields[2] == "kB", let value = Double(fields[1]), value.isFinite, value >= 0 {
                    values[String(fields[0].dropLast())] = value * 1024
                }
            }
            sample.memoryFree = values["MemFree"]
            sample.memoryCached = values["Cached"]
            sample.swapFree = values["SwapFree"]
            sample.swapTotal = values["SwapTotal"]
            if let total = values["MemTotal"], total > 0 {
                let available = values["MemAvailable"] ?? fallbackAvailable(values)
                sample.memoryTotal = total
                if let available { sample.memoryUsed = min(total, max(0, total - available)) }
            }
        }
        if let disks = sections["__TERMIND_DISKS__"], !disks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var result: [String: MetricsCounters] = [:]
            for line in disks.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 8, let read = UInt64(fields[3]), let write = UInt64(fields[7]),
                    read <= UInt64.max / 512, write <= UInt64.max / 512
                else { continue }
                result[String(fields[0])] = MetricsCounters(
                    read: read * 512, write: write * 512,
                    readOperations: UInt64(fields[1]), writeOperations: UInt64(fields[5]),
                    busyMilliseconds: fields.count > 10 ? UInt64(fields[10]) : nil,
                    readMilliseconds: UInt64(fields[4]), writeMilliseconds: fields.count > 8 ? UInt64(fields[8]) : nil
                )
            }
            sample.disks = result.isEmpty ? nil : result
        }
        if let network = sections["__TERMIND_NETWORK__"] {
            var result: [String: MetricsCounters] = [:]
            for line in network.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let fields = parts[1].split(whereSeparator: \.isWhitespace)
                guard name != "lo", fields.count >= 16, let read = UInt64(fields[0]), let write = UInt64(fields[8])
                else { continue }
                result[name] = MetricsCounters(read: read, write: write)
            }
            sample.interfaces = result.isEmpty ? nil : result
        }
        if let blocks = sections["__TERMIND_BLOCKS__"] {
            var counters: [String: MetricsCounters] = [:]
            for line in blocks.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 13, let read = UInt64(fields[4]), let write = UInt64(fields[8]),
                    read <= UInt64.max / 512, write <= UInt64.max / 512
                else { continue }
                counters[String(fields[0])] = MetricsCounters(
                    read: read * 512, write: write * 512,
                    readOperations: UInt64(fields[2]), writeOperations: UInt64(fields[6]),
                    busyMilliseconds: UInt64(fields[11]), readMilliseconds: UInt64(fields[5]),
                    writeMilliseconds: UInt64(fields[9])
                )
            }
            sample.blocks = counters
        }
        for line in sections["__TERMIND_INTERFACES__", default: ""].split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2 {
                sample.interfaceKinds[String(fields[0])] = MetricsInterfaceKind(rawValue: String(fields[1])) ?? .unknown
            }
        }
        for line in sections["__TERMIND_ADDRESSES__", default: ""].split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, fields[2] == "inet" || fields[2] == "inet6", !line.contains("scope link") else {
                continue
            }
            let name = String(fields[1].split(separator: "@").first ?? fields[1])
            let address = String(fields[3].split(separator: "/").first ?? fields[3])
            sample.interfaceAddresses[name, default: []].append(address)
        }
        let tcpLines = sections["__TERMIND_TCP__", default: ""].split(separator: "\n").filter { $0.hasPrefix("Tcp:") }
        if tcpLines.count == 2 {
            let names = tcpLines[0].split(whereSeparator: \.isWhitespace).dropFirst()
            let numbers = tcpLines[1].split(whereSeparator: \.isWhitespace).dropFirst()
            if names.count == numbers.count {
                let values = Dictionary(
                    zip(names.map(String.init), numbers.map { UInt64($0) }), uniquingKeysWith: { _, last in last })
                sample.tcp = MetricsTCP(
                    active: values["ActiveOpens"] ?? nil, passive: values["PassiveOpens"] ?? nil,
                    failures: values["AttemptFails"] ?? nil, retransmitted: values["RetransSegs"] ?? nil,
                    sent: values["OutSegs"] ?? nil)
            }
        }
        return sample
    }

    private static func fallbackAvailable(_ values: [String: Double]) -> Double? {
        guard let free = values["MemFree"], let buffers = values["Buffers"], let cached = values["Cached"]
        else { return nil }
        return free + buffers + cached
    }
}
