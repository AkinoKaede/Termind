import Foundation
import TermindDomain

@MainActor
public final class RepositoryHostDeletionHandler: OutboxEventHandler {
    public nonisolated let handlerID: String
    private let repository: any HostRepository

    public init(handlerID: String, repository: any HostRepository) {
        self.handlerID = handlerID
        self.repository = repository
    }

    public func handle(type: String, payload: Data, eventID: UUID) async throws {
        guard type == HostDeletionOutbox.eventType else { return }
        let deletion = try JSONDecoder().decode(HostDeletionPayload.self, from: payload)
        switch handlerID {
        case HostDeletionOutbox.clearReferences:
            try repository.clearReferencesForDeletedHost(deletion.hostID)
        case HostDeletionOutbox.finalize:
            try repository.finalizeHostDeletion(deletion.hostID)
        default:
            break
        }
    }
}

@MainActor
public final class RuntimeHostDeletionHandler: OutboxEventHandler {
    public nonisolated let handlerID: String
    private let action: (HostDeletionPayload) -> Void

    public init(handlerID: String, action: @escaping (HostDeletionPayload) -> Void) {
        self.handlerID = handlerID
        self.action = action
    }

    public func handle(type: String, payload: Data, eventID: UUID) async throws {
        guard type == HostDeletionOutbox.eventType else { return }
        action(try JSONDecoder().decode(HostDeletionPayload.self, from: payload))
    }
}
