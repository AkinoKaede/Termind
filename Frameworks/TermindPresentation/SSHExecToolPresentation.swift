// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// Localized SSH projections composed into each app's trusted presenter registry.
nonisolated public enum SSHExecToolPresentation {
    private static let names: Set<String> = [
        TermindToolName.sshExecRun, TermindToolName.runSnippet, TermindToolName.sshExecOutput,
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

    static let profiles: [String: AgentToolPresentationProfile] = Dictionary(
        uniqueKeysWithValues: names.map { name in
            var profile = AgentToolPresentationProfile()
            profile.phaseSummary = { phase, activity, target, locale in
                phaseSummary(phase, activity: activity, target: target, locale: locale)
            }
            profile.detail = { card, _, locale in
                guard card.result == nil else { return .useDefault }
                return .content(
                    .init(
                        items: present(
                            .init(
                                result: .object([:]), arguments: card.invocation.call.arguments.objectValue ?? [:],
                                locale: locale),
                            name: name, pending: true)))
            }
            return ("builtin.\(name)", profile)
        })

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
        if name == TermindToolName.sshExecRun || name == TermindToolName.runSnippet {
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
        let output = object["output"]?.stringValue ?? ""
        if !output.isEmpty { items.append(block(S.output, output)) }
        if [TermindToolName.sshExecRun, TermindToolName.sshExecOutput].contains(name), output.isEmpty {
            items.append(pending ? .message(text(S.pending), .secondary) : field(S.noOutput))
        }
        if let note = object["note"]?.stringValue { items.append(.message(note, .warning)) }
        return items
    }

    private static func phaseSummary(
        _ kind: AgentToolDescriptor.Presentation.PhaseKind,
        activity: String, target: String?, locale: Locale
    ) -> String? {
        // Commands already carry their own shell punctuation. English reads
        // more naturally without another pair of prose quotes around the
        // entire command, while Chinese and Japanese use quotation marks to separate the
        // command from the surrounding sentence.
        if !AgentToolPresentation().usesLocalizedActionTemplates(locale) {
            return switch kind {
            case .sshPreparingCommand:
                target.map { "Preparing to run \(activity) on \($0)" }
                    ?? "Preparing to run \(activity)"
            case .sshWaitingForCommand:
                target.map { "Waiting to run \(activity) on \($0)" }
                    ?? "Waiting to run \(activity)"
            case .sshWaitingForAuthentication:
                target.map { "Waiting to authenticate with \($0)" }
                    ?? "Waiting for authentication"
            case .sshConnecting:
                target.map { "Connecting to \($0)" } ?? "Connecting"
            case .sshRunningCommand:
                target.map { "Running \(activity) on \($0)" } ?? "Running \(activity)"
            case .sshCompletedCommand:
                target.map { "Ran \(activity) on \($0)" } ?? "Ran \(activity)"
            case .sshDeniedCommand:
                target.map { "Did not run \(activity) on \($0)" }
                    ?? "Did not run \(activity)"
            case .sshFailedCommand:
                target.map { "Failed to run \(activity) on \($0)" }
                    ?? "Failed to run \(activity)"
            case .sshInterruptedCommand:
                target.map { "Stopped waiting for \(activity) on \($0)" }
                    ?? "Stopped waiting for \(activity)"
            default: nil
            }
        }
        switch kind {
        case .sshPreparingCommand:
            return target.map {
                AppLocalization.resolve("Preparing to run “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Preparing to run “\(activity)”", locale: locale)
        case .sshWaitingForCommand:
            return target.map {
                AppLocalization.resolve("Waiting to run “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Waiting to run “\(activity)”", locale: locale)
        case .sshWaitingForAuthentication:
            return target.map {
                AppLocalization.resolve("Waiting to authenticate with \($0)", locale: locale)
            } ?? AppLocalization.resolve("Waiting for authentication", locale: locale)
        case .sshConnecting:
            return target.map {
                AppLocalization.resolve("Connecting to \($0)", locale: locale)
            } ?? AppLocalization.resolve(AppStrings.Connections.connecting, locale: locale)
        case .sshRunningCommand:
            return target.map {
                AppLocalization.resolve("Running “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Running “\(activity)”", locale: locale)
        case .sshCompletedCommand:
            return target.map {
                AppLocalization.resolve("Ran “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Ran “\(activity)”", locale: locale)
        case .sshDeniedCommand:
            return target.map {
                AppLocalization.resolve("Did not run “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Did not run “\(activity)”", locale: locale)
        case .sshFailedCommand:
            return target.map {
                AppLocalization.resolve("Failed to run “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Failed to run “\(activity)”", locale: locale)
        case .sshInterruptedCommand:
            return target.map {
                AppLocalization.resolve("Stopped waiting for “\(activity)” on \($0)", locale: locale)
            } ?? AppLocalization.resolve("Stopped waiting for “\(activity)”", locale: locale)
        // Open vocabulary. A phase this app has no wording for falls back to the
        // ordinary action lifecycle, which is what the caller does with `nil`.
        default:
            return nil
        }
    }

}
