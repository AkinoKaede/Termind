import Foundation
import SwiftData
import TermindApplication
import TermindDomain

@MainActor
public final class SwiftDataToolAuditRepository: ToolAuditRepository {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func entries() throws -> [ExternalToolCall] {
        try context.fetch(
            FetchDescriptor<PersistentExternalToolCall>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    public func clear() throws {
        try context.commit { try context.delete(model: PersistentExternalToolCall.self) }
    }

    public func insert(_ value: ExternalToolCall, limit: Int) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            descriptor.fetchOffset = max(0, limit - 1)
            for old in try context.fetch(descriptor) { context.delete(old) }
            context.insert(PersistentExternalToolCall(value))
        }
    }

    public func update(_ value: ExternalToolCall) throws {
        try context.commit {
            let id = value.id
            var descriptor = FetchDescriptor<PersistentExternalToolCall>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            try context.fetch(descriptor).first?.apply(value)
        }
    }

    public func value(id: ExternalToolCall.ID) throws -> ExternalToolCall? {
        var descriptor = FetchDescriptor<PersistentExternalToolCall>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.value
    }

    public func recoverInterruptedCalls() throws {
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
