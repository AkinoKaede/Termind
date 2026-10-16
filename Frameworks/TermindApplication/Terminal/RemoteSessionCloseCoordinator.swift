import Foundation
import Observation
import TermindDomain

@MainActor
@Observable
public final class RemoteSessionCloseCoordinator {
    public private(set) var isClosing = false
    private var generation = UUID()

    public init() {}

    public func cancel() {
        generation = UUID()
    }

    /// Ending an owned session is best-effort; failures fall back to disconnecting
    /// without discarding its recovery identity or interrupting the close with UI.
    public func close(
        attachments: [RemoteSessionReference], intent: TerminalTeardownIntent = .explicitClose,
        terminate: @MainActor (RemoteSessionReference) async throws -> Void
    ) async -> Bool {
        guard intent.endsManagedSession else { return true }
        let managed = attachments.filter(\.isManaged).reduce(into: [RemoteSessionReference]()) { unique, reference in
            if !unique.contains(where: { $0.hasSameIdentity(as: reference) }) { unique.append(reference) }
        }
        guard !managed.isEmpty else { return true }
        guard !isClosing else { return false }
        let attempt = generation
        isClosing = true
        defer { isClosing = false }
        for attachment in managed {
            guard generation == attempt, !Task.isCancelled else { return false }
            do {
                try await terminate(attachment)
            } catch is CancellationError {
                return false
            } catch {
                // Ownership checks still apply. Never force termination or mark a failed session ended.
            }
        }
        return generation == attempt && !Task.isCancelled
    }
}
