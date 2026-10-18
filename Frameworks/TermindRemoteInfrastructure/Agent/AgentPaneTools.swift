import AgentKit
import Foundation
import TermindApplication

nonisolated public struct ListPanesTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(id: "builtin.list_panes", present: present)
    public let panes: AgentPaneAccess

    public init(panes: AgentPaneAccess) { self.panes = panes }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        let rows =
            input.result.objectValue?["panes"]?.arrayValue?.compactMap { value -> AgentToolDetail.ListRow? in
                guard let pane = value.objectValue,
                    let title = pane["title"]?.stringValue,
                    let id = pane["pane_id"]?.stringValue
                else { return nil }
                var badges: [String] = []
                if pane["is_active"]?.boolValue == true {
                    badges.append(AgentPaneToolCopy.localized("Active in window", locale: input.locale))
                }
                if pane["is_current"]?.boolValue == true {
                    badges.append(AgentPaneToolCopy.localized("Current in Assistant window", locale: input.locale))
                }
                return .init(title: title, subtitle: id, badges: badges, symbol: "terminal")
            } ?? []
        return [
            .list(
                .init(
                    rows: rows, emptyMessage: AgentPaneToolCopy.localized("No open terminals", locale: input.locale)))
        ]
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            TermindToolName.listPanes,
            "List metadata for open terminal panes on this device, including hidden panes. Use read_pane directly when the intended pane_id is already known from session context or a prior result. is_active is per window; is_current identifies the current terminal in this run's window.",
            properties: [:], required: [], target: .local, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "rectangle.split.2x1", activity: .label("terminals"), output: .json, actionKind: .list)
        )
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let rows = await panes.list().map { pane in
            AgentJSONValue.object([
                "pane_id": .string(pane.id.uuidString),
                "title": .string(pane.title),
                "host_id": pane.hostID.map { .string($0.uuidString) } ?? .null,
                "workspace": .string(pane.workspace),
                "window": .string(pane.window),
                "is_active": .bool(pane.isActive),
                "is_current": .bool(pane.isCurrent),
            ])
        }
        return Self.result(invocation, .object(["panes": .array(rows)]))
    }
}

nonisolated public struct ReadPaneTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.read_pane", layout: .init(truncateStrategy: .none), present: present)
    public let panes: AgentPaneAccess
    public var truncateStrategy: AgentTruncateStrategy { .none }

    public init(panes: AgentPaneAccess) { self.panes = panes }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        let object = input.result.objectValue ?? [:]
        var items: [AgentToolDetail.Item] = []
        if let title = object["title"]?.stringValue {
            items.append(
                .field(
                    .init(
                        label: AgentPaneToolCopy.localized("Terminal name", locale: input.locale), value: title)))
        }
        if let id = object["pane_id"]?.stringValue ?? input.arguments["pane_id"]?.stringValue {
            items.append(
                .field(
                    .init(
                        label: AgentPaneToolCopy.localized("Pane ID", locale: input.locale),
                        value: id, isMonospaced: true)))
        }
        return items
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            TermindToolName.readPane,
            "Read the visible viewport of an open terminal pane on this device while preserving focus, scroll position, selection, and clipboard. pane_id is required: use the terminal ID from session context or a prior tool result. Call read_pane directly when the intended ID is known; use list_panes to discover an unknown or unavailable target.",
            properties: ["pane_id": Self.string(max: 64)], required: ["pane_id"],
            target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(symbol: "terminal", activity: .label("terminal"), output: .json, actionKind: .read)
        )
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        guard let id = UUID(uuidString: try arguments.string("pane_id")) else {
            throw AgentToolError.invalidArguments(
                "pane_id is not a valid UUID. Use the intended pane ID from session context or list_panes.")
        }
        let read = await panes.read(id)
        switch read {
        case .closed:
            throw AgentToolError.invalidArguments("Pane is not open. Call list_panes for a current pane ID.")
        case .notConnected:
            throw AgentToolError.invalidArguments("The pane is not connected. Call list_panes for a readable pane ID.")
        case .noSurface:
            throw AgentToolError.invalidArguments("The pane's terminal surface is not established.")
        case .text(let pane, let text):
            return Self.result(
                invocation,
                .object([
                    "pane_id": .string(pane.id.uuidString),
                    "title": .string(pane.title),
                    "host_id": pane.hostID.map { .string($0.uuidString) } ?? .null,
                    "text": .string(text),
                    "truncated": .bool(false),
                ]))
        }
    }

}

nonisolated private enum AgentPaneToolCopy {
    // These keys are owned by shared AppStrings and the app's manually managed catalog.
    // This UI-neutral presenter cannot import Presentation; the app projection
    // uses AppStrings directly and this fallback resolves the same catalog keys.
    static func localized(_ key: String.LocalizationValue, locale: Locale) -> String {
        AppLocalization.string(key, locale: locale)
    }
}
