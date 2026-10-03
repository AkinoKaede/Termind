import Foundation

public nonisolated struct ShellHistorySource: Sendable, Equatable {
    public enum Shell: String, Sendable { case bash, zsh, fish }
    public var shell: Shell
    /// nil asks for the shell's default; empty explicitly disables file history.
    public var path: String?

    public init(shell: Shell, path: String? = nil) {
        self.shell = shell
        self.path = path
    }
}

public nonisolated struct ShellHistoryRecord: Sendable, Equatable {
    public var command: String
    public var executedAt: Date?
    public var duration: TimeInterval?

    public init(command: String, executedAt: Date? = nil, duration: TimeInterval? = nil) {
        self.command = command
        self.executedAt = executedAt
        self.duration = duration
    }
}

public nonisolated enum ShellHistoryFilter {
    public static func isIntegrationCommand(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anchored signatures, not substring matches: echo/grep of these names is user work.
        if text.hasPrefix("command true '__TRMD_"), text.contains("_PROBE__'") { return true }
        if text.hasPrefix("if [[ ") || text.hasPrefix("if not set -q "),
            text.contains("__termind_integration_token"),
            text.contains("__termind_report_prompt"), text.contains("_DONE__")
        {
            return true
        }
        let name = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return [
            "__termind_report_command", "__termind_report_prompt", "__termind_report_cwd",
            "__termind_report_finished", "__termind_prompt_begin", "__termind_prompt_end",
            "__termind_compose_draft", "__termind_compose_clear",
        ].contains(String(name))
    }
}

/// Parses complete records in file order. It never invents timestamps or evaluates shell text.
public nonisolated enum ShellHistoryParser {
    public static func parse(
        _ text: String, shell: ShellHistorySource.Shell, truncatedStart: Bool = false
    ) -> [ShellHistoryRecord] {
        var lines = text.components(separatedBy: "\n")
        // A file being appended may end halfway through a record. Only newline-terminated text is complete.
        if !lines.isEmpty { lines.removeLast() }
        if truncatedStart, !lines.isEmpty { lines.removeFirst() }
        let records: [ShellHistoryRecord]
        switch shell {
        case .bash: records = bash(lines, truncatedStart: truncatedStart)
        case .zsh: records = zsh(lines, truncatedStart: truncatedStart)
        case .fish: records = fish(lines)
        }
        return records.filter {
            !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !ShellHistoryFilter.isIntegrationCommand($0.command)
        }
    }

    private static func timestamp(_ text: String) -> Date? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let seconds = Double(text),
            seconds.isFinite, seconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func bash(_ lines: [String], truncatedStart: Bool) -> [ShellHistoryRecord] {
        let hasMarkers = lines.contains { $0.hasPrefix("#") && timestamp(String($0.dropFirst())) != nil }
        if !hasMarkers { return plain(lines) }
        var records: [ShellHistoryRecord] = []
        var date: Date?
        var command: [String] = []
        var accepts = !truncatedStart
        func flush() {
            if accepts, !command.isEmpty {
                records.append(ShellHistoryRecord(command: command.joined(separator: "\n"), executedAt: date))
            }
            command.removeAll()
        }
        for line in lines {
            if line.hasPrefix("#"), let next = timestamp(String(line.dropFirst())) {
                flush()
                date = next
                accepts = true
            } else {
                command.append(line)
            }
        }
        flush()
        return records
    }

    private static func plain(_ lines: [String]) -> [ShellHistoryRecord] {
        var result: [ShellHistoryRecord] = []
        var pending = ""
        for line in lines {
            pending += line
            if trailingBackslashes(line).isMultiple(of: 2) {
                result.append(ShellHistoryRecord(command: pending))
                pending = ""
            } else {
                pending += "\n"
            }
        }
        return result
    }

    private static func trailingBackslashes(_ line: String) -> Int {
        line.reversed().prefix { $0 == "\\" }.count
    }

    private static func zsh(_ lines: [String], truncatedStart: Bool) -> [ShellHistoryRecord] {
        var result: [ShellHistoryRecord] = []
        var pending: ShellHistoryRecord?
        var continuing = false
        let extended = lines.contains { header($0) != nil }
        var accepts = !truncatedStart || !extended
        for line in lines {
            if !continuing {
                if let parsed = header(line) {
                    pending = parsed
                    accepts = true
                } else if accepts {
                    pending = ShellHistoryRecord(command: line)
                }
            } else {
                pending?.command += "\n" + line
            }
            continuing = line.hasSuffix("\\")
            if continuing {
                // Zsh uses backslash + physical newline to serialize a literal newline.
                if pending != nil { pending!.command.removeLast() }
            } else if let record = pending {
                result.append(record)
                pending = nil
            }
        }
        return result
    }

    private static func header(_ line: String) -> ShellHistoryRecord? {
        guard line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") else { return nil }
        let fields = line[line.index(line.startIndex, offsetBy: 2)..<semicolon].split(separator: ":")
        guard fields.count == 2, let date = timestamp(String(fields[0])),
            let duration = Double(fields[1]), duration.isFinite, duration >= 0
        else { return nil }
        return ShellHistoryRecord(
            command: String(line[line.index(after: semicolon)...]), executedAt: date, duration: duration)
    }

    private static func fish(_ lines: [String]) -> [ShellHistoryRecord] {
        var records: [ShellHistoryRecord] = []
        var current: ShellHistoryRecord?
        for line in lines {
            if line.hasPrefix("- cmd: ") {
                if let current { records.append(current) }
                current = ShellHistoryRecord(command: fishUnescape(String(line.dropFirst(7))))
            } else if line.hasPrefix("  when: ") {
                current?.executedAt = timestamp(String(line.dropFirst(8)))
            }
        }
        if let current { records.append(current) }
        return records
    }

    private static func fishUnescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                if next == "n" {
                    result.append("\n")
                } else if next == "\\" {
                    result.append("\\")
                } else {
                    result.append("\\")
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }
}
