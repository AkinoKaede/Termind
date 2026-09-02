import AgentKit
import Foundation

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

/// The two SSH checkpoints a run may reach, as one value the surface supplies.
///
/// Termind's, not the runtime's. `AgentUserInteractionHandling` carries the
/// model-authored question every adopter has; credentials and host-key trust are
/// ours because hosts are, so they travel to the tools that need them through
/// `AgentToolServices` instead of through a runtime protocol.
///
/// Closures rather than a protocol because the supplier is always an actor-bound
/// object — a conversation, the external-request coordinator — and the tools
/// need neither its identity nor anything else it can do.
///
/// Being outside the runtime is also what keeps this path silent. A credential
/// prompt raises no `AgentEvent` and writes no durable record, because it never
/// passes through `AgentEventChannel` at all — previously a wrapper had to
/// deliberately forward these two methods without emitting.
nonisolated struct AgentSSHInteraction: Sendable {
    typealias Authenticating =
        @Sendable (AgentSSHAuthenticationRequest) async -> AgentSSHAuthenticationResponse
    typealias HostKeyConfirming =
        @Sendable (AgentSSHHostKeyRequest) async -> AgentSSHHostKeyResponse

    var authenticate: Authenticating
    var confirmHostKey: HostKeyConfirming

    /// What a run that cannot ask anybody does: refuse, rather than connect with
    /// whatever is lying around.
    static let unavailable = AgentSSHInteraction(
        authenticate: { _ in .cancelled }, confirmHostKey: { _ in .deny }
    )
}

nonisolated extension AgentToolServiceKey where Service == AgentSSHInteraction {
    static let sshInteraction = AgentToolServiceKey<AgentSSHInteraction>(
        "termind.ssh-interaction"
    )
}

nonisolated extension AgentToolExecutionContext {
    /// The SSH prompt for this run, or one that refuses everything.
    ///
    /// Falling back rather than throwing: a host that registered the SSH tools
    /// and forgot the service has a bug, and the honest outcome of that bug is a
    /// connection that could not be authorized — not a crash inside a tool call.
    var sshInteraction: AgentSSHInteraction {
        services[.sshInteraction] ?? .unavailable
    }
}
