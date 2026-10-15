import Foundation
import Observation
import TermindDomain

@MainActor
@Observable
public final class RemoteSessionCloseCoordinator {
    public struct Prompt: Identifiable {
        public let id = UUID()
        public let names: [String]
        public let failure: String?
    }

    public enum Choice { case cancel, endSessions, disconnectOnly }
    public private(set) var prompt: Prompt?
    public private(set) var isClosing = false
    private var continuation: CheckedContinuation<Choice, Never>?
    private var generation = UUID()

    public init() {}

    public func cancel() {
        generation = UUID()
        if let prompt { choose(.cancel, for: prompt.id) }
    }

    public func choose(_ choice: Choice, for id: UUID) {
        guard prompt?.id == id else { return }
        prompt = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: choice)
    }

    /// A failed termination never grants permission to remove the workspace.
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
        var remaining = managed
        var failure: String?
        while !remaining.isEmpty {
            guard generation == attempt, !Task.isCancelled else { return false }
            if let failure {
                let request = Prompt(names: remaining.map(\.session.name), failure: failure)
                let choice = await withTaskCancellationHandler {
                    await withCheckedContinuation {
                        continuation = $0
                        prompt = request
                        if Task.isCancelled { choose(.cancel, for: request.id) }
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in self?.choose(.cancel, for: request.id) }
                }
                switch choice {
                case .cancel: return false
                case .disconnectOnly: return generation == attempt && !Task.isCancelled
                case .endSessions: break
                }
            }
            do {
                while let attachment = remaining.first {
                    try Task.checkCancellation()
                    guard generation == attempt else { return false }
                    try await terminate(attachment)
                    remaining.removeFirst()
                }
                guard generation == attempt, !Task.isCancelled else { return false }
            } catch {
                failure = error.localizedDescription
            }
        }
        return true
    }
}
