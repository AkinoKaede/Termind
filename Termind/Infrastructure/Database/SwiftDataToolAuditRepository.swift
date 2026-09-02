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

    init(_ value: ExternalToolCall) { apply(value) }

    func apply(_ value: ExternalToolCall) {
        id = value.id
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

@MainActor
final class SwiftDataToolAuditRepository: ToolAuditRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func entries() throws -> [ExternalToolCall] {
        try context.fetch(
            FetchDescriptor<PersistentExternalToolCall>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    func clear() throws {
        try context.commit { try context.delete(model: PersistentExternalToolCall.self) }
    }

    func insert(_ value: ExternalToolCall, limit: Int) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            descriptor.fetchOffset = max(0, limit - 1)
            for old in try context.fetch(descriptor) { context.delete(old) }
            context.insert(PersistentExternalToolCall(value))
        }
    }

    func update(_ value: ExternalToolCall) throws {
        try context.commit {
            let id = value.id
            var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            try context.fetch(descriptor).first?.apply(value)
        }
    }

    func value(id: ExternalToolCall.ID) throws -> ExternalToolCall? {
        var descriptor = FetchDescriptor<PersistentExternalToolCall>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.value
    }

    func recoverInterruptedCalls() throws {
        let running = ExternalToolCall.Status.running.rawValue
        try context.commit {
            let rows = try context.fetch(
                FetchDescriptor<PersistentExternalToolCall>(
                    predicate: #Predicate { $0.status == running }
                ))
            for row in rows {
                row.status = ExternalToolCall.Status.error.rawValue
                row.finishedAt = .now
            }
        }
    }

}

extension ToolAuditModel {
    convenience init(
        modelContext: ModelContext,
        hostName: @escaping (Host.ID) -> String? = { _ in nil }
    ) {
        self.init(
            repository: SwiftDataToolAuditRepository(context: modelContext),
            hostName: hostName
        )
    }
}
