import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

import struct TermindDomain.Host

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
