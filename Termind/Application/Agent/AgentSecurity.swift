import Foundation

nonisolated struct AgentApprovalRequest: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var invocation: AgentToolInvocation
    var descriptor: AgentToolDescriptor
    var userIntent: String
    var localReasons: [String] = []
}

nonisolated enum AgentApprovalDecision: Hashable, Sendable {
    case allow
    case deny(String)
}

nonisolated enum SecurityReviewRisk: String, Hashable, Sendable, Codable {
    case low, medium, high, critical
}

nonisolated enum SecurityReviewVerdict: String, Hashable, Sendable, Codable {
    case approve, deny
}

nonisolated enum SecurityReviewAuthorization: String, Hashable, Sendable, Codable {
    case sufficient, insufficient
}

nonisolated struct SecurityReviewDecision: Hashable, Sendable, Codable {
    var verdict: SecurityReviewVerdict
    var risk: SecurityReviewRisk
    var userAuthorization: SecurityReviewAuthorization
    var reason: String

    var allowsExecution: Bool {
        guard verdict == .approve, risk != .critical else { return false }
        return risk != .high || userAuthorization == .sufficient
    }
}

nonisolated protocol SecurityReviewing: Sendable {
    func review(_ request: AgentApprovalRequest) async throws -> SecurityReviewDecision
}

nonisolated protocol AgentApprovalHandling: Sendable {
    func authorize(
        _ request: AgentApprovalRequest,
        mode: ChatPermissionMode
    ) async -> AgentApprovalDecision
}

/// Implements Termind's three permission modes. Reviewer failures are deliberately
/// fail-closed, matching Codex Auto-review rather than silently becoming approval.
actor AgentApprovalBroker: AgentApprovalHandling {
    typealias ManualApproval = @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision

    private let reviewer: (any SecurityReviewing)?
    private let manualApproval: ManualApproval
    private let event: @Sendable (AgentEvent) -> Void
    private let reviewTimeout: Duration

    init(
        reviewer: (any SecurityReviewing)?,
        manualApproval: @escaping ManualApproval,
        reviewTimeout: Duration = .seconds(30),
        event: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.reviewer = reviewer
        self.manualApproval = manualApproval
        self.reviewTimeout = reviewTimeout
        self.event = event
    }

    func authorize(
        _ request: AgentApprovalRequest,
        mode: ChatPermissionMode
    ) async -> AgentApprovalDecision {
        if request.descriptor.safety == .locallyReadOnly { return .allow }
        if mode == .fullAccess { return .allow }

        if request.descriptor.alwaysAskUser || mode == .askForApproval {
            event(.approvalRequested(request))
            return await manualApproval(request)
        }

        guard mode == .approveForMe, let reviewer else {
            return .deny(String(localized: "Security Review is unavailable; the action was not executed."))
        }
        event(.reviewStarted(request))
        do {
            let decision = try await reviewWithTimeout(reviewer, request: request)
            event(.reviewFinished(request, decision))
            return decision.allowsExecution ? .allow : .deny(decision.reason)
        } catch is SecurityReviewTimeoutError {
            let reason = String(localized: "Security Review timed out; the action was not executed.")
            event(.reviewFailed(request, reason: reason, timedOut: true))
            return .deny(reason)
        } catch {
            let reason = String(
                localized: "Security Review failed; the action was not executed. \(error.localizedDescription)"
            )
            event(.reviewFailed(request, reason: reason, timedOut: false))
            return .deny(reason)
        }
    }

    private func reviewWithTimeout(
        _ reviewer: any SecurityReviewing,
        request: AgentApprovalRequest
    ) async throws -> SecurityReviewDecision {
        try await withThrowingTaskGroup(of: SecurityReviewDecision.self) { group in
            group.addTask { try await reviewer.review(request) }
            group.addTask { [reviewTimeout] in
                try await Task.sleep(for: reviewTimeout)
                throw SecurityReviewTimeoutError()
            }
            guard let first = try await group.next() else { throw SecurityReviewTimeoutError() }
            group.cancelAll()
            return first
        }
    }
}

private nonisolated struct SecurityReviewTimeoutError: Error, Sendable {}

nonisolated struct SecretBinding: Hashable, Sendable {
    var runID: UUID
    var toolName: String
    var hostID: UUID?
    var purpose: String
}

nonisolated struct SecretHandle: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
}

nonisolated enum SecretBrokerError: LocalizedError, Sendable, Equatable {
    case notFound, bindingMismatch

    var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "The secret is unavailable or has already been used.")
        case .bindingMismatch: String(localized: "The secret is not valid for this host, tool, or purpose.")
        }
    }
}

/// Plaintext exists only in this actor and in the executor call that consumes it.
/// A failed binding check does not consume the handle; a successful read always does.
actor SecretBroker {
    private struct Entry {
        var secret: String
        var binding: SecretBinding
    }
    private var entries: [SecretHandle.ID: Entry] = [:]

    func issue(_ secret: String, binding: SecretBinding) -> SecretHandle {
        let handle = SecretHandle(id: UUID())
        entries[handle.id] = Entry(secret: secret, binding: binding)
        return handle
    }

    func consume(_ handle: SecretHandle, matching binding: SecretBinding) throws -> String {
        guard let entry = entries[handle.id] else { throw SecretBrokerError.notFound }
        guard entry.binding == binding else { throw SecretBrokerError.bindingMismatch }
        entries[handle.id] = nil
        return entry.secret
    }

    func discardSecrets(for runID: UUID) {
        entries = entries.filter { $0.value.binding.runID != runID }
    }

    var count: Int { entries.count }
}

nonisolated struct AgentUserInputRequest: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable { case text, choice([String]), secret }
    var id: UUID = UUID()
    var prompt: String
    var kind: Kind
    var purpose: String = ""
    var hostID: UUID?
}

nonisolated enum AgentUserInputResponse: Hashable, Sendable {
    case text(String)
    case secret(String)
    case cancelled
}

nonisolated protocol AgentUserInteractionHandling: Sendable {
    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse
}

nonisolated struct UnavailableAgentUserInteraction: AgentUserInteractionHandling, Sendable {
    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse { .cancelled }
}
