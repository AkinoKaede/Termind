import AgentKit
import Foundation
import TermindApplication

/// Localized SSH projections composed into each app's trusted presenter registry.
nonisolated public enum SSHExecToolPresentation {
    private static let names: Set<String> = [
        "ssh_exec", "ssh_wait", TermindToolName.sshExecRun, TermindToolName.sshExecOutput,
        TermindToolName.sshExecStdin, TermindToolName.sshExecCancel, TermindToolName.sshExecList,
    ]

    /// Replace only the SSH result projections. Tool-owned layout, approval arguments,
    /// and operation policies remain attached to the same persisted presenter IDs.
    public static func registering(in registry: AgentToolPresenterRegistry) -> AgentToolPresenterRegistry {
        AgentToolPresenterRegistry(
            registry.ids.compactMap { id in
                guard let original = registry.presenter(id: id) else { return nil }
                guard let name = names.first(where: { id == "builtin.\($0)" }) else { return original }
                return AgentToolDetailPresenter(
                    id: id, layout: original.layout,
                    present: { present($0, name: name) },
                    presentArguments: {
                        original.presentArguments($0)
                            ?? AgentToolDetailFormatting.genericItems(.object($0.arguments), locale: $0.locale)
                    },
                    operation: { original.resolveOperation(arguments: $0) })
            })
    }

    /// Result-less historical cards do not have a result projection to invoke yet.
    static func pendingDetail(for card: AgentToolCard, locale: Locale) -> AgentToolDetail? {
        guard card.result == nil, card.descriptor.target != .mcp, names.contains(card.descriptor.name),
            card.descriptor.presentation?.presenterID == nil
                || card.descriptor.presentation?.presenterID == "builtin.\(card.descriptor.name)"
        else { return nil }
        return .init(
            items: present(
                .init(
                    result: .object([:]), arguments: card.invocation.call.arguments.objectValue ?? [:], locale: locale),
                name: card.descriptor.name, pending: true))
    }

    private static func present(
        _ input: AgentToolDetailInput, name: String, pending: Bool = false
    ) -> [AgentToolDetail.Item] {
        guard let object = input.result.objectValue else {
            return AgentToolDetailFormatting.genericItems(input.result, locale: input.locale)
        }
        let args = input.arguments
        typealias S = AppStrings.SSHExec
        func text(_ resource: LocalizedStringResource) -> String {
            AppLocalization.resolve(resource, locale: input.locale)
        }
        func field(_ title: LocalizedStringResource, _ value: String = "", mono: Bool = false) -> AgentToolDetail.Item {
            .field(.init(label: text(title), value: value, isMonospaced: mono))
        }
        func block(
            _ title: LocalizedStringResource, _ value: String, isCollapsible: Bool = true
        ) -> AgentToolDetail.Item {
            .text(.init(title: text(title), text: value, style: .monospaced, isCollapsible: isCollapsible))
        }
        func status(_ value: String) -> String {
            switch value {
            case "written": text(S.written)
            case "closed": text(S.stdinClosed)
            case "released": text(S.released)
            default: AgentToolDetailFormatting.statusLabel(value, locale: input.locale)
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
            return rows.isEmpty ? [.message(text(S.noCommands), .secondary)] : [.list(.init(rows: rows))]
        }
        var items: [AgentToolDetail.Item] = []
        if let command = args["command"]?.stringValue {
            items.append(block(S.command, command, isCollapsible: false))
        }
        if name == TermindToolName.sshExecRun {
            items.append(field(args["run_in_background"]?.boolValue == true ? S.background : S.foreground))
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
        if let count = object["bytes_written"]?.integerValue {
            items.append(field(S.written, DataSizeFormat.bytes(count), mono: true))
        }
        if let closed = object["stdin_closed"]?.boolValue {
            items.append(field(closed ? S.stdinClosed : S.stdinOpen))
        }
        if let error = object["error"]?.stringValue { items.append(.message(error, .failure)) }
        if object["remote_termination_confirmed"]?.boolValue == false {
            items.append(.message(text(S.cancellationNotice), .warning))
        }
        let stdout = object["output"]?.stringValue ?? object["stdout"]?.stringValue ?? ""
        let stderr = object["stderr"]?.stringValue ?? ""
        if !stdout.isEmpty { items.append(block(object["output"] == nil ? S.stdout : S.output, stdout)) }
        if !stderr.isEmpty { items.append(block(S.stderr, stderr)) }
        if ["ssh_exec", "ssh_wait", TermindToolName.sshExecRun, TermindToolName.sshExecOutput]
            .contains(name), stdout.isEmpty, stderr.isEmpty
        {
            items.append(pending ? .message(text(S.pending), .secondary) : field(S.noOutput))
        }
        if let note = object["note"]?.stringValue { items.append(.message(note, .warning)) }
        return items
    }
}
