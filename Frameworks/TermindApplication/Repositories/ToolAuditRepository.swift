import Foundation
import TermindDomain

@MainActor
public protocol ToolAuditRepository: AnyObject {
    func entries() throws -> [ExternalToolCall]
    func clear() throws
    func insert(_ value: ExternalToolCall, limit: Int) throws
    func update(_ value: ExternalToolCall) throws
    func value(id: ExternalToolCall.ID) throws -> ExternalToolCall?
    func recoverInterruptedCalls() throws
}

@MainActor
public final class InMemoryToolAuditRepository: ToolAuditRepository {
    private var values: [ExternalToolCall]

    public init(entries: [ExternalToolCall] = []) { values = entries }

    public func entries() throws -> [ExternalToolCall] {
        values.sorted { $0.startedAt > $1.startedAt }
    }

    public func clear() throws { values.removeAll() }

    public func insert(_ value: ExternalToolCall, limit: Int) throws {
        values.append(value)
        values.sort { $0.startedAt > $1.startedAt }
        if values.count > limit { values.removeLast(values.count - limit) }
    }

    public func update(_ value: ExternalToolCall) throws {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        }
    }

    public func value(id: ExternalToolCall.ID) throws -> ExternalToolCall? {
        values.first { $0.id == id }
    }

    public func recoverInterruptedCalls() throws {
        for index in values.indices where values[index].status == .running {
            values[index].status = .error
            values[index].finishedAt = .now
        }
    }
}
