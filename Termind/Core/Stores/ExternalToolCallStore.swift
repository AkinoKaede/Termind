import Foundation
import SwiftData

@Model
final class PersistentExternalToolCall {
    @Attribute(.unique) var id: UUID = UUID()
    var runID: UUID = UUID()
    var clientName = ""
    var toolName = ""
    var hostID: UUID?
    var hostDisplayName: String?
    var summary = ""
    var risk = ExternalToolCall.Risk.readOnly.rawValue
    var status = ExternalToolCall.Status.running.rawValue
    var exitCode: Int?
    var bytesRead: Int?
    var bytesWritten: Int?
    var startedAt = Date(timeIntervalSince1970: 0)
    var finishedAt: Date?

    init(_ value: ExternalToolCall) {
        id = value.id
        apply(value)
    }

    func apply(_ value: ExternalToolCall) {
        runID = value.runID
        clientName = value.clientName
        toolName = value.toolName
        hostID = value.hostID
        hostDisplayName = value.hostDisplayName
        summary = value.summary
        risk = value.risk.rawValue
        status = value.status.rawValue
        exitCode = value.exitCode
        bytesRead = value.bytesRead
        bytesWritten = value.bytesWritten
        startedAt = value.startedAt
        finishedAt = value.finishedAt
    }

    var value: ExternalToolCall {
        ExternalToolCall(
            id: id, runID: runID, clientName: clientName, toolName: toolName,
            hostID: hostID, hostDisplayName: hostDisplayName, summary: summary,
            risk: ExternalToolCall.Risk(rawValue: risk) ?? .readOnly,
            status: ExternalToolCall.Status(rawValue: status) ?? .error,
            exitCode: exitCode, bytesRead: bytesRead, bytesWritten: bytesWritten,
            startedAt: startedAt, finishedAt: finishedAt
        )
    }
}

/// Privacy-bounded audit history for tools invoked through the local MCP server.
/// It consumes the existing ordered event channel, but deliberately reconstructs
/// only metadata. Tool results and file bodies never enter this store.
@MainActor
@Observable
final class ExternalToolCallStore {
    static let globalLimit = 2_000

    private let context: ModelContext?
    private let hostName: (Host.ID) -> String?
    private var memoryEntries: [ExternalToolCall]
    private var clients: [UUID: String] = [:]
    private var rowsByInvocation: [AgentToolInvocation.ID: ExternalToolCall.ID] = [:]
    private var handleHosts: [UUID: (Host.ID, String?)] = [:]
    private var consumer: Task<Void, Never>?
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(
        entries: [ExternalToolCall] = [],
        hostName: @escaping (Host.ID) -> String? = { _ in nil }
    ) {
        context = nil
        memoryEntries = Array(
            entries.sorted { $0.startedAt > $1.startedAt }.prefix(Self.globalLimit)
        )
        self.hostName = hostName
    }

    init(modelContext: ModelContext, hostName: @escaping (Host.ID) -> String? = { _ in nil }) {
        context = modelContext
        memoryEntries = []
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
        let values: [ExternalToolCall]
        if let context {
            do {
                values = try context.fetch(FetchDescriptor<PersistentExternalToolCall>(
                    sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
                )).map(\.value)
                storageError = nil
            } catch {
                storageError = error.localizedDescription
                return []
            }
        } else {
            values = memoryEntries.sorted { $0.startedAt > $1.startedAt }
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
            if let context {
                try context.delete(model: PersistentExternalToolCall.self)
                try context.save()
            } else {
                memoryEntries.removeAll()
            }
            rowsByInvocation.removeAll()
            storageError = nil
            revision &+= 1
        } catch {
            context?.rollback()
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
            toolName: descriptor.name,
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
            if let context {
                var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                    sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
                )
                descriptor.fetchOffset = Self.globalLimit - 1
                for old in try context.fetch(descriptor) { context.delete(old) }
                context.insert(PersistentExternalToolCall(value))
                try context.save()
            } else {
                memoryEntries.append(value)
                if memoryEntries.count > Self.globalLimit {
                    memoryEntries.sort { $0.startedAt > $1.startedAt }
                    memoryEntries.removeLast(memoryEntries.count - Self.globalLimit)
                }
            }
            storageError = nil
            revision &+= 1
        } catch {
            context?.rollback()
            storageError = error.localizedDescription
        }
    }

    private func update(_ value: ExternalToolCall) {
        do {
            if let context {
                let rowID = value.id
                var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                    predicate: #Predicate { $0.id == rowID }
                )
                descriptor.fetchLimit = 1
                try context.fetch(descriptor).first?.apply(value)
                try context.save()
            } else if let index = memoryEntries.firstIndex(where: { $0.id == value.id }) {
                memoryEntries[index] = value
            }
            storageError = nil
            revision &+= 1
        } catch {
            context?.rollback()
            storageError = error.localizedDescription
        }
    }

    private func value(id: UUID) -> ExternalToolCall? {
        if let context {
            var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first?.value
        }
        return memoryEntries.first { $0.id == id }
    }

    private func recoverInterruptedCalls() {
        guard let context else { return }
        do {
            let running = ExternalToolCall.Status.running.rawValue
            let rows = try context.fetch(FetchDescriptor<PersistentExternalToolCall>(
                predicate: #Predicate { $0.status == running }
            ))
            for row in rows {
                row.status = ExternalToolCall.Status.error.rawValue
                row.finishedAt = .now
            }
            if !rows.isEmpty { try context.save() }
        } catch {
            context.rollback()
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
