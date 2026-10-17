import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated public struct ListHostsTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.list_hosts", present: present
    )
    public let hosts: AgentHostResolver

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "list_hosts",
            """
            List Vault Hosts and temporary terminal targets without credentials, even when no session context \
            is available, including each target's enabled protocol list. SSH and SFTP tools require a returned \
            protocol entry named ssh; Telnet targets are discoverable but no Agent Telnet execution tool is currently \
            available.
            """,
            properties: [:], required: [], target: .host, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "server.rack", activity: .semanticLabel(.hosts), output: .json,
                actionKind: .list
            )
        )
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let listing = await hosts.listing()
        let rows = listing.hosts.map { target in
            let protocols = target.protocols.map { connectionProtocol in
                AgentJSONValue.object([
                    "name": .string(connectionProtocol.name.rawValue),
                    "address": .string(connectionProtocol.address),
                    "connection_state": .string(connectionProtocol.connectionState),
                ])
            }
            return AgentJSONValue.object([
                "id": .string(target.id.uuidString), "display_name": .string(target.displayName),
                "address": .string(target.address), "tags": .array(target.tags.map(AgentJSONValue.string)),
                "connection_state": .string(target.connectionState), "temporary": .bool(target.isTemporary),
                "group_id": target.groupID.map { .string($0.uuidString) } ?? .null,
                "group_path": target.groupPath.map(AgentJSONValue.string) ?? .null,
                "preferred_terminal_protocol": .string(target.preferredTerminalProtocol.rawValue),
                "protocols": .array(protocols),
            ])
        }
        func groupJSON(_ group: AgentHostGroupTarget) -> AgentJSONValue {
            .object([
                "id": .string(group.id.uuidString), "name": .string(group.name),
                "path": .string(group.path), "children": .array(group.children.map(groupJSON)),
            ])
        }
        return Self.result(
            invocation,
            .object([
                "groups": .array(listing.groups.map(groupJSON)), "hosts": .array(rows),
            ]))
    }

    public init(hosts: AgentHostResolver) {
        self.hosts = hosts
    }
}

nonisolated public struct TerminalSuggestTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.terminal_suggest", present: present
    )
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "terminal_suggest",
            """
            Create a command card when the user wants a suggestion or needs to interact with a PTY. \
            Only the user can insert or run the card. This tool does not execute commands or return \
            execution output, and the sending surface may mark it unavailable at execution time. To run a remote \
            command yourself, use ssh_exec_run.
            """,
            properties: [
                "command": Self.string(max: 32_768)
            ],
            required: ["command"], target: .user, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "terminal", activity: .semanticLabel(.suggestion),
                groupsWithAdjacentTools: false, actionKind: .provide
            )
        )
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let command = try arguments.string("command")
        guard !command.contains("\n"), !command.contains("\r"), !command.contains("\0") else {
            throw AgentToolError.invalidArguments("A terminal suggestion must be one command line.")
        }
        return Self.result(
            invocation,
            .object([
                "command": .string(command),
                "risk": .string(CommandRiskClassifier.assess(command).risk.label),
                "requires_user_action": .bool(true),
            ]))
    }
}

nonisolated extension TerminalSuggestTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        let object = input.result.objectValue ?? [:]
        let command =
            input.arguments["command"]?.stringValue
            ?? object["command"]?.stringValue ?? ""
        var items: [AgentToolDetail.Item] = [F.text("Command", command, locale: input.locale)]
        let assessment = CommandRiskClassifier.assess(command)
        items.append(F.field("Risk", assessment.risk.label, locale: input.locale))
        items.append(contentsOf: assessment.reasons.map { .message($0, .warning) })
        items.append(.message(F.localized("Requires user action", locale: input.locale), .warning))
        return items
    }
}

nonisolated public enum SSHCommandPresentation {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            if let status = object["status"]?.stringValue {
                items.append(
                    F.field(
                        "Status", F.statusLabel(status, locale: input.locale), locale: input.locale
                    ))
            }
            if let code = object["exit_code"]?.integerValue {
                items.append(F.field("Exit code", String(code), locale: input.locale, monospaced: true))
            }
            F.appendField(
                &items, "Signal", object["signal"]?.stringValue,
                locale: input.locale, monospaced: true)
            let stdout = object["output"]?.stringValue ?? object["stdout"]?.stringValue ?? ""
            let stderr = object["stderr"]?.stringValue ?? ""
            if !stdout.isEmpty {
                items.append(
                    F.text(object["output"] == nil ? "Standard output" : "Content", stdout, locale: input.locale))
            }
            if !stderr.isEmpty { items.append(F.text("Standard error", stderr, locale: input.locale)) }
            if stdout.isEmpty, stderr.isEmpty, object["note"] == nil {
                items.append(.message(F.localized("No output", locale: input.locale), .secondary))
            }
            if let note = F.nonempty(object["note"]?.stringValue) {
                items.append(.message(note, .warning))
            }
            return items
        }
    }
}

// MARK: - Tool-owned transcript details

nonisolated extension ListHostsTool {

    private struct HostGroupDetailProjection {
        let id: String
        let title: String
    }

    public static func present(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            let hostValues = object["hosts"]?.arrayValue ?? []
            let groupValues = object["groups"]?.arrayValue ?? []
            var groups: [HostGroupDetailProjection] = []

            func walk(_ rows: [AgentJSONValue], prefix: String = "") {
                for row in rows {
                    guard let fields = row.objectValue else { continue }
                    let name =
                        F.nonempty(fields["name"]?.stringValue)
                        ?? F.localized("Unnamed group", locale: input.locale)
                    let computed = prefix.isEmpty ? name : "\(prefix) / \(name)"
                    let title = F.nonempty(fields["path"]?.stringValue) ?? computed
                    if let id = fields["id"]?.stringValue {
                        groups.append(.init(id: id, title: title))
                    }
                    walk(fields["children"]?.arrayValue ?? [], prefix: computed)
                }
            }
            walk(groupValues)

            var grouped: [String: [AgentToolDetail.ListRow]] = [:]
            var ungrouped: [AgentToolDetail.ListRow] = []
            var temporary: [AgentToolDetail.ListRow] = []
            var connected = 0
            for hostValue in hostValues {
                guard let host = hostValue.objectValue else { continue }
                if host["connection_state"]?.stringValue == "connected" { connected += 1 }
                let row = hostDetailRow(host, locale: input.locale)
                if host["temporary"]?.boolValue == true {
                    temporary.append(row)
                } else if let groupID = host["group_id"]?.stringValue,
                    groups.contains(where: { $0.id == groupID })
                {
                    grouped[groupID, default: []].append(row)
                } else {
                    ungrouped.append(row)
                }
            }

            guard !hostValues.isEmpty || !groups.isEmpty else {
                return [.message(F.localized("No hosts available", locale: input.locale), .secondary)]
            }
            func hostCount(_ count: Int) -> String {
                String(localized: "\(count) hosts", locale: input.locale)
            }
            var summary = [hostCount(hostValues.count)]
            if connected > 0 {
                summary.append(String(localized: "\(connected) connected", locale: input.locale))
            }
            if !temporary.isEmpty {
                summary.append(String(localized: "\(temporary.count) temporary", locale: input.locale))
            }
            var sections = groups.map { group in
                let rows = grouped[group.id] ?? []
                return AgentToolDetail.ListSection(
                    title: "\(group.title) · \(hostCount(rows.count))", rows: rows
                )
            }
            if !groups.isEmpty || !ungrouped.isEmpty {
                sections.append(
                    .init(
                        title: "\(F.localized("Ungrouped", locale: input.locale)) · \(hostCount(ungrouped.count))",
                        rows: ungrouped
                    ))
            }
            if !temporary.isEmpty {
                sections.append(
                    .init(
                        title: "\(F.localized("Temporary", locale: input.locale)) · \(hostCount(temporary.count))",
                        rows: temporary
                    ))
            }
            return [
                .groupedList(
                    .init(
                        summary: summary.joined(separator: " · "), sections: sections,
                        isScrollable: hostValues.count > 12
                    ))
            ]
        }
    }

    private static func hostDetailRow(
        _ host: [String: AgentJSONValue], locale: Locale
    ) -> AgentToolDetail.ListRow {
        typealias F = AgentToolDetailFormatting
        let address = F.nonempty(host["address"]?.stringValue)
        let name =
            F.nonempty(host["display_name"]?.stringValue) ?? address
            ?? F.localized("Unnamed host", locale: locale)
        let state = connectionDetailState(host["connection_state"]?.stringValue ?? "", locale: locale)
        let subtitle = [address ?? F.localized("Address unavailable", locale: locale), state.label]
            .joined(separator: " · ")
        let tags = host["tags"]?.arrayValue?.compactMap { F.nonempty($0.stringValue) } ?? []
        return .init(
            title: name, subtitle: subtitle, badges: tags, symbol: "circle.fill", tint: state.tint
        )
    }

    private static func connectionDetailState(
        _ raw: String, locale: Locale
    ) -> (label: String, tint: AgentToolDetail.Tint) {
        typealias F = AgentToolDetailFormatting
        return switch raw {
        case "connected": (F.localized("Connected", locale: locale), AgentToolDetail.Tint.success)
        case "connecting": (F.localized("Connecting", locale: locale), AgentToolDetail.Tint.warning)
        case "reconnecting": (F.localized("Reconnecting", locale: locale), AgentToolDetail.Tint.warning)
        case "disconnected": (F.localized("Not connected", locale: locale), AgentToolDetail.Tint.secondary)
        case "failed": (F.localized("Failed", locale: locale), AgentToolDetail.Tint.failure)
        default:
            (
                F.nonempty(F.humanized(raw))?.capitalized
                    ?? F.localized("Unknown", locale: locale),
                AgentToolDetail.Tint.secondary
            )
        }
    }

}
