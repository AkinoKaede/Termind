import Foundation

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
@Observable
final class ExternalAuthCoordinator {
    enum Request {
        case ssh(AgentSSHAuthenticationRequest)
        case secret(AgentUserInputRequest)

        var id: UUID {
            switch self {
            case .ssh(let request): request.id
            case .secret(let request): request.id
            }
        }
    }

    struct Pending: Identifiable {
        var id: UUID { request.id }
        var runID: UUID
        var clientName: String
        var request: Request
    }

    nonisolated struct Handler: AgentUserInteractionHandling, Sendable {
        let clientName: String
        let runID: UUID
        let coordinator: ExternalAuthCoordinator

        func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
            await coordinator.enqueue(request, clientName: clientName, runID: runID)
        }

        func requestSSHAuthentication(
            _ request: AgentSSHAuthenticationRequest
        ) async -> AgentSSHAuthenticationResponse {
            await coordinator.enqueue(request, clientName: clientName, runID: runID)
        }
    }

    private(set) var pending: [Pending] = []
    private(set) var presentationRevision: UInt64 = 0
    private var sshWaiters:
        [UUID: CheckedContinuation<AgentSSHAuthenticationResponse, Never>] = [:]
    private var secretWaiters:
        [UUID: CheckedContinuation<AgentUserInputResponse, Never>] = [:]

    var current: Pending? { pending.first }

    func handler(clientName: String, runID: UUID) -> Handler {
        Handler(clientName: clientName, runID: runID, coordinator: self)
    }

    func enqueue(
        _ request: AgentSSHAuthenticationRequest, clientName: String, runID: UUID
    ) async -> AgentSSHAuthenticationResponse {
        append(.ssh(request), clientName: clientName, runID: runID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { sshWaiters[request.id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.id) }
        }
    }

    func enqueue(
        _ request: AgentUserInputRequest, clientName: String, runID: UUID
    ) async -> AgentUserInputResponse {
        guard request.questions.count == 1,
            request.questions.allSatisfy({ if case .secret = $0.kind { true } else { false } })
        else { return .cancelled }
        append(.secret(request), clientName: clientName, runID: runID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { secretWaiters[request.id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.id) }
        }
    }

    func respondSSH(_ response: AgentSSHAuthenticationResponse) {
        guard case .ssh? = current?.request, let request = removeCurrent() else { return }
        sshWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    func respondSecret(_ response: AgentUserInputResponse) {
        guard case .secret? = current?.request, let request = removeCurrent() else { return }
        secretWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    func windowClosed() { cancelAll() }

    func cancelAll() {
        let sshContinuations = sshWaiters.values
        let secretContinuations = secretWaiters.values
        sshWaiters.removeAll()
        secretWaiters.removeAll()
        pending.removeAll()
        for continuation in sshContinuations { continuation.resume(returning: .cancelled) }
        for continuation in secretContinuations { continuation.resume(returning: .cancelled) }
    }

    func cancel(runID: UUID) {
        let ids = pending.filter { $0.runID == runID }.map(\.id)
        for id in ids { cancel(id) }
    }

    private func append(_ request: Request, clientName: String, runID: UUID) {
        let wasEmpty = pending.isEmpty
        pending.append(Pending(
            runID: runID, clientName: String(clientName.prefix(160)), request: request
        ))
        if wasEmpty { presentCurrent() }
    }

    private func removeCurrent() -> Pending? {
        guard !pending.isEmpty else { return nil }
        let request = pending.removeFirst()
        if !pending.isEmpty { presentCurrent() }
        return request
    }

    private func presentCurrent() {
        presentationRevision &+= 1
        #if canImport(AppKit)
            NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    private func cancel(_ id: UUID) {
        let wasCurrent = pending.first?.id == id
        pending.removeAll { $0.id == id }
        sshWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
        secretWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
        if wasCurrent, !pending.isEmpty { presentCurrent() }
    }
}
