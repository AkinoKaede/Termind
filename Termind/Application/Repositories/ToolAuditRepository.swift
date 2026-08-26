import Foundation

@MainActor
protocol ToolAuditRepository: AnyObject {
    func entries() throws -> [ExternalToolCall]
    func clear() throws
    func insert(_ value: ExternalToolCall, limit: Int) throws
    func update(_ value: ExternalToolCall) throws
    func value(id: ExternalToolCall.ID) throws -> ExternalToolCall?
    func recoverInterruptedCalls() throws
}

@MainActor
final class InMemoryToolAuditRepository: ToolAuditRepository {
    private var values: [ExternalToolCall]

    init(entries: [ExternalToolCall] = []) { values = entries }

    func entries() throws -> [ExternalToolCall] {
        values.sorted { $0.startedAt > $1.startedAt }
    }

    func clear() throws { values.removeAll() }

    func insert(_ value: ExternalToolCall, limit: Int) throws {
        values.append(value)
        values.sort { $0.startedAt > $1.startedAt }
        if values.count > limit { values.removeLast(values.count - limit) }
    }

    func update(_ value: ExternalToolCall) throws {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        }
    }

    func value(id: ExternalToolCall.ID) throws -> ExternalToolCall? {
        values.first { $0.id == id }
    }

    func recoverInterruptedCalls() throws {
        for index in values.indices where values[index].status == .running {
            values[index].status = .error
            values[index].finishedAt = .now
        }
    }
}

