import Foundation
import TermindApplication
import TermindDomain

@MainActor
final class RepositoryHostDeletionHandler: OutboxEventHandler {
    nonisolated let handlerID: String
    private let repository: any HostRepository

    init(handlerID: String, repository: any HostRepository) {
        self.handlerID = handlerID
        self.repository = repository
    }

    func handle(type: String, payload: Data, eventID: UUID) async throws {
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
final class RuntimeHostDeletionHandler: OutboxEventHandler {
    nonisolated let handlerID: String
    private let action: (HostDeletionPayload) -> Void

    init(handlerID: String, action: @escaping (HostDeletionPayload) -> Void) {
        self.handlerID = handlerID
        self.action = action
    }

    func handle(type: String, payload: Data, eventID: UUID) async throws {
        guard type == HostDeletionOutbox.eventType else { return }
        action(try JSONDecoder().decode(HostDeletionPayload.self, from: payload))
    }
}
