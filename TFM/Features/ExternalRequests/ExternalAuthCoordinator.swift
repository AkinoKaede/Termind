import AgentKit
import Foundation
import Logging
import TermindApplication

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
@Observable
final class ExternalAuthCoordinator {
    enum Request {
        case ssh(AgentSSHAuthenticationRequest)
        case hostKey(AgentSSHHostKeyRequest)
        case secret(AgentUserInputRequest)

        var id: UUID {
            switch self {
            case .ssh(let request): request.id
            case .hostKey(let request): request.id
            case .secret(let request): request.id
            }
        }

        var hostID: UUID? {
            switch self {
            case .ssh(let request): request.hostID
            case .hostKey(let request): request.hostID
            case .secret: nil
            }
        }
    }

    struct Pending: Identifiable {
        var id: UUID { request.id }
        var operationID: String
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

        /// The SSH checkpoints, in the shape the tools take them — see
        /// `AgentSSHInteraction`. They queue in the same window as the secret
        /// prompt above; only the route differs.
        var sshInteraction: AgentSSHInteraction {
            AgentSSHInteraction(
                authenticate: { [clientName, runID, coordinator] request in
                    await coordinator.enqueue(
                        request, clientName: clientName, runID: runID
                    )
                },
                confirmHostKey: { [clientName, runID, coordinator] request in
                    await coordinator.enqueue(
                        request, clientName: clientName, runID: runID
                    )
                }
            )
        }
    }

    private(set) var pending: [Pending] = []
    private(set) var presentationRevision: UInt64 = 0
    private var sshWaiters: [UUID: CheckedContinuation<AgentSSHAuthenticationResponse, Never>] = [:]
    private var secretWaiters: [UUID: CheckedContinuation<AgentUserInputResponse, Never>] = [:]
    private var hostKeyWaiters: [UUID: CheckedContinuation<AgentSSHHostKeyResponse, Never>] = [:]
    private var appAuthenticationRuns: Set<UUID> = []
    private var secretTimeoutTask: Task<Void, Never>?
    private let logger: Logger
    private var presentedRequestIDs: Set<UUID> = []

    init(logger: Logger = ApplicationLogger.disabled("termind.external-mcp")) {
        self.logger = logger
    }

    var current: Pending? { pending.first }

    nonisolated var keyboardInteractive: SSHKeyboardInteractiveHandler {
        { [weak self] challenge in
            guard let self else { throw CancellationError() }
            return try await self.answerAppChallenge(challenge)
        }
    }

    nonisolated var securityKeySigning: SecurityKeySigningHandler {
        { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.signAppSecurityKey(request)
        }
    }

    private func signAppSecurityKey(_ request: SecurityKeySigningRequest) async throws -> SecurityKeyAssertion {
        appAuthenticationRuns.insert(request.id)
        defer { appAuthenticationRuns.remove(request.id) }
        return try await handler(clientName: "Termind", runID: request.id)
            .sshInteraction.signSecurityKey(request, invocationID: request.id)
    }

    private func answerAppChallenge(_ challenge: SSHKeyboardInteractiveChallenge) async throws -> [String] {
        appAuthenticationRuns.insert(challenge.connectionID)
        defer { appAuthenticationRuns.remove(challenge.connectionID) }
        return try await handler(clientName: "Termind", runID: challenge.connectionID)
            .sshInteraction.respondToChallenge(challenge, invocationID: challenge.id)
    }

    func cancelExternalRequests() {
        let ids = pending.filter { !appAuthenticationRuns.contains($0.runID) }.map(\.id)
        for id in ids { cancel(id) }
    }

    func handler(clientName: String, runID: UUID) -> Handler {
        Handler(clientName: clientName, runID: runID, coordinator: self)
    }

    func enqueue(
        _ request: AgentSSHAuthenticationRequest, clientName: String, runID: UUID
    ) async -> AgentSSHAuthenticationResponse {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                sshWaiters[request.id] = continuation
                append(.ssh(request), clientName: clientName, runID: runID)
                if request.keyboardInteractive?.isInformational == true {
                    Task { [weak self] in
                        await Task.yield()
                        self?.respondSSH(.keyboardInteractive([]), requestID: request.id)
                    }
                }
            }
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                secretWaiters[request.id] = continuation
                append(.secret(request), clientName: clientName, runID: runID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.id) }
        }
    }

    func enqueue(
        _ request: AgentSSHHostKeyRequest, clientName: String, runID: UUID
    ) async -> AgentSSHHostKeyResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                hostKeyWaiters[request.id] = continuation
                append(.hostKey(request), clientName: clientName, runID: runID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.id) }
        }
    }

    func respondSSH(_ response: AgentSSHAuthenticationResponse, requestID: UUID? = nil) {
        guard let id = requestID ?? current?.id,
            let index = pending.firstIndex(where: { $0.id == id }),
            case .ssh = pending[index].request
        else { return }
        let finished: Pending
        if index == 0 { finished = removeCurrent()! } else { finished = pending.remove(at: index) }
        logFinished(finished, outcome: Self.sshOutcome(response))
        sshWaiters.removeValue(forKey: id)?.resume(returning: response)
    }

    func respondSecret(_ response: AgentUserInputResponse) {
        guard case .secret? = current?.request, let request = removeCurrent() else { return }
        logFinished(request, outcome: "submitted")
        secretWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    func respondHostKey(_ response: AgentSSHHostKeyResponse) {
        guard case .hostKey? = current?.request, let request = removeCurrent() else { return }
        logFinished(request, outcome: Self.hostKeyOutcome(response))
        hostKeyWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    func windowClosed() { cancelAll() }

    /// A scene can finish disappearing after SwiftUI has already opened its
    /// replacement for a newer request. Only the window that actually displayed
    /// the current checkpoint is allowed to treat its close as user cancellation.
    func windowClosed(presenting requestID: UUID?) {
        guard let requestID, current?.id == requestID else { return }
        cancelAll()
    }

    func cancelAll() {
        secretTimeoutTask?.cancel()
        secretTimeoutTask = nil
        let sshContinuations = sshWaiters.values
        let secretContinuations = secretWaiters.values
        let hostKeyContinuations = hostKeyWaiters.values
        sshWaiters.removeAll()
        secretWaiters.removeAll()
        hostKeyWaiters.removeAll()
        let cancelled = pending
        pending.removeAll()
        for request in cancelled { logFinished(request, outcome: "cancelled") }
        for continuation in sshContinuations { continuation.resume(returning: .cancelled) }
        for continuation in secretContinuations { continuation.resume(returning: .cancelled) }
        for continuation in hostKeyContinuations { continuation.resume(returning: .deny) }
    }

    func cancel(hostID: UUID) {
        let ids = pending.compactMap { item -> UUID? in
            if case .ssh(let request) = item.request, request.hostID == hostID { return item.id }
            return nil
        }
        for id in ids { cancel(id) }
    }

    func cancel(runID: UUID) {
        let ids = pending.filter { $0.runID == runID }.map(\.id)
        for id in ids { cancel(id) }
    }

    private func append(_ request: Request, clientName: String, runID: UUID) {
        let wasEmpty = pending.isEmpty
        let item = Pending(
            operationID: UUID().uuidString.lowercased(), runID: runID,
            clientName: String(clientName.prefix(160)), request: request
        )
        pending.append(item)
        if clientName != "Termind" {
            var metadata: Logger.Metadata = [
                "authentication": Self.kind(request), "component": "external_mcp",
                "operation_id": "\(item.operationID)", "stage": "queued",
            ]
            if let hostID = request.hostID { metadata["host_id"] = "\(hostID.uuidString.lowercased())" }
            logger.info(
                "external_mcp.prompt.requested",
                metadata: metadata)
        }
        if wasEmpty { presentCurrent() }
    }

    func markPresented(_ id: UUID) {
        guard presentedRequestIDs.insert(id).inserted,
            let request = pending.first(where: { $0.id == id }), request.clientName != "Termind"
        else { return }
        var metadata: Logger.Metadata = [
            "authentication": Self.kind(request.request), "component": "external_mcp",
            "operation_id": "\(request.operationID)", "stage": "presented",
        ]
        if let hostID = request.request.hostID { metadata["host_id"] = "\(hostID.uuidString.lowercased())" }
        logger.info(
            "external_mcp.prompt.presented",
            metadata: metadata)
    }

    private func removeCurrent() -> Pending? {
        guard !pending.isEmpty else { return nil }
        secretTimeoutTask?.cancel()
        secretTimeoutTask = nil
        let request = pending.removeFirst()
        if !pending.isEmpty { presentCurrent() }
        return request
    }

    private func presentCurrent() {
        presentationRevision &+= 1
        scheduleSecretTimeout()
        #if canImport(AppKit)
            NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    private func cancel(_ id: UUID) {
        let wasCurrent = pending.first?.id == id
        let cancelled = pending.first { $0.id == id }
        pending.removeAll { $0.id == id }
        if wasCurrent {
            secretTimeoutTask?.cancel()
            secretTimeoutTask = nil
        }
        sshWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
        secretWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
        hostKeyWaiters.removeValue(forKey: id)?.resume(returning: .deny)
        if let cancelled { logFinished(cancelled, outcome: "cancelled") }
        if wasCurrent, !pending.isEmpty { presentCurrent() }
    }

    private func logFinished(_ request: Pending, outcome: String) {
        presentedRequestIDs.remove(request.id)
        guard request.clientName != "Termind" else { return }
        var metadata: Logger.Metadata = [
            "authentication": Self.kind(request.request), "component": "external_mcp",
            "operation_id": "\(request.operationID)", "outcome": "\(outcome)", "stage": "finished",
        ]
        if let hostID = request.request.hostID { metadata["host_id"] = "\(hostID.uuidString.lowercased())" }
        logger.info(
            "external_mcp.prompt.finished",
            metadata: metadata)
    }

    private static func kind(_ request: Request) -> Logger.Metadata.Value {
        switch request {
        case .ssh: "ssh_authentication"
        case .hostKey: "host_key"
        case .secret: "secret"
        }
    }

    private static func sshOutcome(_ response: AgentSSHAuthenticationResponse) -> String {
        switch response {
        case .submit: "submitted"
        case .keyboardInteractive, .securityKey: "submitted"
        case .securityKeyFailed: "failed"
        case .cancelled: "cancelled"
        }
    }

    private static func hostKeyOutcome(_ response: AgentSSHHostKeyResponse) -> String {
        switch response {
        case .continueOnce: "continued_once"
        case .trustAndContinue: "trusted"
        case .deny: "denied"
        }
    }

    private func scheduleSecretTimeout() {
        secretTimeoutTask?.cancel()
        guard case .secret(let request)? = current?.request else {
            secretTimeoutTask = nil
            return
        }
        secretTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: request.timeout)
            } catch {
                return
            }
            self?.timeOutSecret(request.id)
        }
    }

    private func timeOutSecret(_ id: UUID) {
        guard case .secret? = current?.request, current?.id == id,
            let request = removeCurrent()
        else { return }
        secretWaiters.removeValue(forKey: request.id)?.resume(returning: .timedOut)
    }
}
