import AgentKit
import Foundation
import TermindApplication

/// Shared by native macOS and iOS cards, including pre-rename transcript records.
nonisolated enum SSHExecToolPresentation {
    static let names: Set<String> = [
        "ssh_exec", "ssh_wait", "ssh_exec_run", "ssh_exec_output", "ssh_exec_stdin", "ssh_exec_cancel", "ssh_exec_list",
    ]

    static func detail(for card: AgentToolCard, locale: Locale) -> AgentToolDetail? {
        guard card.descriptor.target != .mcp, names.contains(card.descriptor.name) else { return nil }
        let args = card.invocation.call.arguments.objectValue ?? [:]
        let object: [String: AgentJSONValue]
        if let result = card.result {
            guard let parsed = try? AgentJSONValue.decode(Data((result.untrustedPayload ?? result.content).utf8)),
                let fields = parsed.objectValue
            else { return nil }
            object = fields
        } else {
            object = [:]
        }
        typealias S = AppStrings.SSHExec
        func text(_ resource: LocalizedStringResource) -> String { AppLocalization.resolve(resource, locale: locale) }
        func field(_ title: LocalizedStringResource, _ value: String, mono: Bool = false) -> AgentToolDetail.Item {
            .field(.init(label: text(title), value: value, isMonospaced: mono))
        }
        func block(_ title: LocalizedStringResource, _ value: String) -> AgentToolDetail.Item {
            .text(.init(title: text(title), text: value, style: .monospaced))
        }
        func status(_ value: String) -> String {
            switch value {
            case "written": text(S.written)
            case "closed": text(S.stdinClosed)
            case "released": text(S.released)
            default: AgentToolDetailFormatting.statusLabel(value, locale: locale)
            }
        }
        if let commands = object["commands"]?.arrayValue {
            let rows = commands.compactMap { value -> AgentToolDetail.ListRow? in
                guard let entry = value.objectValue else { return nil }
                let subtitle = [entry["host_id"]?.stringValue, entry["handle"]?.stringValue].compactMap { $0 }
                return .init(
                    title: entry["command"]?.stringValue ?? "", subtitle: subtitle.joined(separator: " · "),
                    badges: [status(entry["status"]?.stringValue ?? "")], symbol: "terminal")
            }
            return .init(items: rows.isEmpty ? [.message(text(S.noCommands), .secondary)] : [.list(.init(rows: rows))])
        }
        var items: [AgentToolDetail.Item] = []
        if let command = args["command"]?.stringValue { items.append(block(S.command, command)) }
        if card.descriptor.name == "ssh_exec_run" {
            items.append(
                .message(text(args["run_in_background"]?.boolValue == true ? S.background : S.foreground), .secondary))
        }
        if let handle = object["handle"]?.stringValue ?? args["handle"]?.stringValue {
            items.append(field(S.handle, handle, mono: true))
        }
        if let value = object["status"]?.stringValue { items.append(field(AppStrings.Common.status, status(value))) }
        if let code = object["exit_code"]?.integerValue { items.append(field(S.exitCode, String(code), mono: true)) }
        if let signal = object["signal"]?.stringValue { items.append(field(S.signal, signal, mono: true)) }
        if let type = args["type"]?.stringValue {
            items.append(field(S.input, text(type == "secret" ? S.secret : type == "eof" ? S.eof : S.text)))
            if type == "text", let input = args["stdin"]?.stringValue { items.append(block(S.input, input)) }
        }
        if let count = object["bytes_written"]?.integerValue { items.append(field(S.bytes, String(count), mono: true)) }
        if let closed = object["stdin_closed"]?.boolValue {
            items.append(.message(text(closed ? S.stdinClosed : S.stdinOpen), .secondary))
        }
        if let error = object["error"]?.stringValue { items.append(.message(error, .failure)) }
        if object["remote_termination_confirmed"]?.boolValue == false {
            items.append(.message(text(S.cancellationNotice), .warning))
        }
        let stdout = object["output"]?.stringValue ?? object["stdout"]?.stringValue ?? ""
        let stderr = object["stderr"]?.stringValue ?? ""
        if !stdout.isEmpty { items.append(block(object["output"] == nil ? S.stdout : S.output, stdout)) }
        if !stderr.isEmpty { items.append(block(S.stderr, stderr)) }
        if ["ssh_exec", "ssh_wait", "ssh_exec_run", "ssh_exec_output"].contains(card.descriptor.name),
            stdout.isEmpty, stderr.isEmpty
        {
            items.append(.message(text(card.result == nil ? S.pending : S.noOutput), .secondary))
        }
        if let note = object["note"]?.stringValue { items.append(.message(note, .warning)) }
        return .init(items: items)
    }
}
