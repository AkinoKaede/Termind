import AgentKit
import Foundation

/// Privacy-bounded audit history for tools invoked through the local MCP server.
/// It consumes the existing ordered event channel, but deliberately reconstructs
/// only metadata. Tool results and file bodies never enter this store.
@MainActor
@Observable
final class ToolAuditModel {
    static let globalLimit = 2_000

    private let repository: any ToolAuditRepository
    private let hostName: (Host.ID) -> String?
    private var clients: [UUID: String] = [:]
    private var rowsByInvocation: [AgentToolInvocation.ID: ExternalToolCall.ID] = [:]
    private var handleHosts: [UUID: (Host.ID, String?)] = [:]
    private var consumer: Task<Void, Never>?
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(
        entries: [ExternalToolCall] = [],
        repository: (any ToolAuditRepository)? = nil,
        hostName: @escaping (Host.ID) -> String? = { _ in nil }
    ) {
        self.repository = repository ?? InMemoryToolAuditRepository(
            entries: Array(
                entries.sorted { $0.startedAt > $1.startedAt }.prefix(Self.globalLimit)
            )
        )
        self.hostName = hostName
        recoverInterruptedCalls()
    }

    func consume(_ channel: AgentEventChannel) {
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await event in channel.events { self?.receive(event) }
        }
    }

    func register(runID: UUID, clientName: String) {
        clients[runID] = String(clientName.prefix(160))
    }

    func unregister(runID: UUID) { clients[runID] = nil }

    func entries(
        matching query: String = "", tool: String? = nil, hostID: Host.ID? = nil
    ) -> [ExternalToolCall] {
        _ = revision
        let values: [ExternalToolCall]
        do {
            values = try repository.entries()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return []
        }
        return values.filter { row in
            (tool == nil || row.toolName == tool)
                && (hostID == nil || row.hostID == hostID)
                && (query.isEmpty
                    || row.clientName.localizedCaseInsensitiveContains(query)
                    || row.toolName.localizedCaseInsensitiveContains(query)
                    || row.hostDisplayName?.localizedCaseInsensitiveContains(query) == true
                    || row.summary.localizedCaseInsensitiveContains(query))
        }
    }

    func clear() {
        do {
            try repository.clear()
            rowsByInvocation.removeAll()
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .toolProposed(let invocation, let descriptor):
            begin(invocation, descriptor: descriptor)
        case .toolFinished(let invocation, let result):
            finish(invocation, result: result)
        default:
            break
        }
    }

    private func begin(_ invocation: AgentToolInvocation, descriptor: AgentToolDescriptor) {
        guard rowsByInvocation[invocation.id] == nil else { return }
        var hostID = invocation.targetHostID
        if descriptor.name == "ssh_wait",
            let raw = invocation.call.arguments.objectValue?["handle"]?.stringValue,
            let handle = UUID(uuidString: raw), let mapped = handleHosts[handle]
        {
            hostID = mapped.0
        }
        let row = ExternalToolCall(
            runID: invocation.runID,
            clientName: clients[invocation.runID] ?? String(localized: "Unknown MCP client"),
            toolName: descriptor.qualifiedName,
            hostID: hostID,
            hostDisplayName: hostID.flatMap(hostName),
            summary: Self.summary(for: invocation.call),
            risk: Self.risk(for: invocation.call, descriptor: descriptor),
            bytesWritten: Self.bytesWritten(for: invocation.call),
            startedAt: invocation.createdAt
        )
        rowsByInvocation[invocation.id] = row.id
        insert(row)
    }

    private func finish(_ invocation: AgentToolInvocation, result: AgentToolResult) {
        guard let rowID = rowsByInvocation.removeValue(forKey: invocation.id),
            var row = value(id: rowID)
        else { return }
        row.status = result.isError ? .error : .ok
        row.finishedAt = .now

        if let payload = result.untrustedPayload,
            let value = try? AgentJSONValue.decode(Data(payload.utf8)),
            let object = value.objectValue
        {
            row.exitCode = object["exit_code"]?.integerValue
            row.bytesRead = object["bytes"]?.integerValue
            if invocation.call.name == "ssh_exec",
                let raw = object["handle"]?.stringValue, let handle = UUID(uuidString: raw),
                let hostID = row.hostID
            {
                handleHosts[handle] = (hostID, row.hostDisplayName)
            }
            if invocation.call.name == "ssh_wait",
                object["status"]?.stringValue == "exited",
                let raw = invocation.call.arguments.objectValue?["handle"]?.stringValue,
                let handle = UUID(uuidString: raw)
            {
                handleHosts[handle] = nil
            }
        }
        update(row)
    }

    private func insert(_ value: ExternalToolCall) {
        do {
            try repository.insert(value, limit: Self.globalLimit)
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func update(_ value: ExternalToolCall) {
        do {
            try repository.update(value)
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func value(id: UUID) -> ExternalToolCall? {
        try? repository.value(id: id)
    }

    private func recoverInterruptedCalls() {
        do {
            try repository.recoverInterruptedCalls()
        } catch {
            storageError = error.localizedDescription
        }
    }

    private static func summary(for call: AgentToolCall) -> String {
        let arguments = call.arguments.objectValue ?? [:]
        func oneLine(_ value: String) -> String {
            value.replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        switch call.name {
        case "ssh_exec": return oneLine(arguments["command"]?.stringValue ?? "")
        case "ssh_wait": return "Handle \(arguments["handle"]?.stringValue ?? "")"
        case "sftp_move":
            return "\(oneLine(arguments["path"]?.stringValue ?? "")) → "
                + oneLine(arguments["destination"]?.stringValue ?? "")
        case "sftp_chmod":
            return "\(oneLine(arguments["path"]?.stringValue ?? "")) "
                + (arguments["mode"]?.stringValue ?? "")
        case let name where name.hasPrefix("sftp_"):
            return oneLine(arguments["path"]?.stringValue ?? "")
        case "list_hosts": return String(localized: "List saved hosts")
        default: return ""
        }
    }

    private static func bytesWritten(for call: AgentToolCall) -> Int? {
        guard call.name == "sftp_write",
            let content = call.arguments.objectValue?["content"]?.stringValue
        else { return nil }
        return content.lengthOfBytes(using: .utf8)
    }

    private static func risk(
        for call: AgentToolCall, descriptor: AgentToolDescriptor
    ) -> ExternalToolCall.Risk {
        if call.name == "ssh_exec",
            let command = call.arguments.objectValue?["command"]?.stringValue
        {
            switch CommandRiskClassifier.assess(command).risk {
            case .safe: return .readOnly
            case .caution: return .modifiesState
            case .destructive: return .destructive
            }
        }
        if descriptor.safety.isAutoAllowed { return .readOnly }
        return call.name == "sftp_delete" ? .destructive : .modifiesState
    }
}
