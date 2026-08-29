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

    var displayName: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .critical: String(localized: "Critical")
        }
    }
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
        if request.descriptor.safety.isAutoAllowed { return .allow }
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

    func discardAll() { entries.removeAll() }

    var count: Int { entries.count }
}

/// One choice offered by `request_user_input`.
///
/// A bare string used to be the whole option, which left the model nowhere to
/// put the tradeoff: it either crammed it into the label or lost it, and the
/// reader was left choosing between four words with no way to tell them apart.
nonisolated struct AgentUserInputOption: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    /// One sentence on what this choice means or costs. Optional, and the
    /// reason this type exists.
    var detail: String = ""
    /// Advisory only. It marks the model's recommendation; it never preselects,
    /// because a preselected answer is one the user can submit without reading.
    var isRecommended: Bool = false
}

nonisolated struct AgentUserInputChoice: Hashable, Sendable {
    var options: [AgentUserInputOption]
    /// Whether the user may answer with something the model did not think of.
    ///
    /// Defaults to true, and that default is the whole point: an agent that
    /// offers four wrong answers and no fifth field leaves Cancel as the only
    /// honest response, and a cancelled run tells it nothing about why.
    var allowsCustomAnswer: Bool = true
    var allowsMultipleAnswers: Bool = false
    var customPlaceholder: String = ""
}

nonisolated enum AgentUserInputLimits {
    /// Codex's ceiling, and for the same reason: past three, a form stops being
    /// a decision and starts being a questionnaire.
    static let maxQuestions = 3
    static let minimumTimeoutSeconds = 1
    static let maximumTimeoutSeconds = 30 * 60
    static let defaultTimeoutSeconds = 5 * 60
}

/// One thing the agent needs decided.
nonisolated struct AgentUserQuestion: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case text
        case choice(AgentUserInputChoice)
        case secret
    }

    /// Named by the model, unique within its request. It wrote the questions
    /// and it reads the answers back by these names, so they are its own
    /// vocabulary rather than an index we assign.
    var id: String
    /// Short label naming the decision, shown above the prompt.
    var header: String = ""
    var prompt: String
    var kind: Kind

    /// The choices this question offers, or none for a free-form one. Saves
    /// every reader of a question from re-matching on `kind` to find out.
    var options: [AgentUserInputOption] {
        guard case .choice(let choice) = kind else { return [] }
        return choice.options
    }
}

/// A set of questions put to the user at once.
///
/// Several rather than one because a group of decisions is usually a group —
/// asking about storage, then about migrations only once storage is answered,
/// hides the second question at the moment it would have informed the first.
/// The tool's calls are `.sequential`, so asking twice in a turn already meant
/// answering twice in a row; this keeps them in one navigable request instead.
nonisolated struct AgentUserInputRequest: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = .now
    var questions: [AgentUserQuestion]
    var purpose: String = ""
    var hostID: UUID?
    /// Starts when this request reaches the head of its presentation queue.
    /// Time spent behind another prompt does not consume this duration.
    var timeout: Duration = .seconds(AgentUserInputLimits.defaultTimeoutSeconds)
}

/// What has been filled into one question so far.
nonisolated struct AgentUserInputDraft: Hashable, Sendable {
    /// The "something else" field, and the whole answer for a free-form
    /// question.
    var text = ""
    var selection: Set<String> = []

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated struct AgentUserInputAnswer: Hashable, Sendable {
    nonisolated enum Value: Hashable, Sendable {
        case text(String)
        /// Selected option ids in the order the question listed them, plus
        /// whatever the user typed instead of — or, when several answers are
        /// allowed, alongside — them. Kept structured rather than flattened to
        /// a string so the tool can hand the model ids it chose itself.
        case choice(selectedIDs: [String], custom: String?)
        case secret(String)
    }

    var questionID: String
    var value: Value
}

nonisolated enum AgentUserInputResponse: Hashable, Sendable {
    /// Only the questions the user actually answered.
    ///
    /// An absent question was skipped, and skipping is itself an answer — the
    /// user declining to decide that one. So there is no `.skipped` case: the
    /// absence carries it, and the tool reports it to the model as a null.
    case answered([AgentUserInputAnswer])
    case cancelled
    case timedOut
}

/// A local SSH checkpoint raised by an Agent Exec or SFTP connection. Unlike
/// `request_user_input`, this request is never model-authored and its answer is
/// never serialized into a tool result. Only public Vault metadata crosses
/// into the view.
nonisolated struct AgentSSHAuthenticationRequest: Identifiable, Hashable, Sendable {
    nonisolated enum Mode: Hashable, Sendable {
        case identity
        case passphrase(keyID: SSHKeyRef.ID)
    }

    var id: UUID = UUID()
    var createdAt: Date = .now
    var invocationID: AgentToolInvocation.ID
    var hostID: Host.ID
    var displayName: String
    var address: String
    var mode: Mode
    var selectedIdentityID: Identity.ID?
    var username: String
    var selectedKeyID: SSHKeyRef.ID?
    var failureMessage: String?

    var requiresPassphrase: Bool {
        if case .passphrase = mode { true } else { false }
    }

    var journeyPrompt: SSHAuthenticationPrompt {
        SSHAuthenticationPrompt(
            host: Host(id: hostID, name: displayName, host: address),
            selectedIdentityID: selectedIdentityID,
            username: username,
            selectedKeyID: selectedKeyID,
            failureMessage: failureMessage,
            requiresPassphrase: requiresPassphrase,
            mode: failureMessage == nil ? .localIdentity : .serverChallenge
        )
    }
}

nonisolated struct AgentSSHAuthenticationAnswer: Hashable, Sendable {
    /// Existing identity when selected; nil means the inline Custom form.
    var identityID: Identity.ID?
    var identityName: String?
    var username: String
    var password: String?
    var passphrase: String?
    var keyID: SSHKeyRef.ID?
    /// Existing identities are bound; inline values create an Identity.
    var save: Bool
}

nonisolated enum AgentSSHAuthenticationResponse: Hashable, Sendable {
    case submit(AgentSSHAuthenticationAnswer)
    case cancelled
}

/// A host-key checkpoint raised locally while an Agent Exec or SFTP transport
/// is being prepared. The observation is public SSH metadata; it is never
/// serialized into the model-facing transcript or a tool result.
nonisolated struct AgentSSHHostKeyRequest: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = .now
    var invocationID: AgentToolInvocation.ID
    var hostID: Host.ID
    var displayName: String
    var address: String
    var prompt: SSHHostKeyPrompt
    /// False for a pane-backed temporary target, which has no Known Hosts
    /// record to update. Its accepted key can only live for this connection.
    var allowsPersistentTrust: Bool
}

nonisolated enum AgentSSHHostKeyResponse: Hashable, Sendable {
    case deny
    case continueOnce
    case trustAndContinue
}

nonisolated protocol AgentUserInteractionHandling: Sendable {
    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse
    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse
    func requestSSHHostKeyConfirmation(
        _ request: AgentSSHHostKeyRequest
    ) async -> AgentSSHHostKeyResponse
}

nonisolated struct UnavailableAgentUserInteraction: AgentUserInteractionHandling, Sendable {
    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse { .cancelled }
    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse { .cancelled }
    func requestSSHHostKeyConfirmation(
        _ request: AgentSSHHostKeyRequest
    ) async -> AgentSSHHostKeyResponse { .deny }
}
