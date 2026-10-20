// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindDomain

import struct TermindDomain.Host

/// A local SSH checkpoint raised by an Agent Exec or SFTP connection. Unlike
/// `request_user_input`, this request is never model-authored and its answer is
/// never serialized into a tool result. Only public Vault metadata crosses
/// into the view.
nonisolated public struct AgentSSHAuthenticationRequest: Identifiable, Hashable, Sendable {
    public nonisolated enum Mode: Hashable, Sendable {
        case securityKey(SecurityKeySigningRequest)
        case identity
        case tailscaleUsername
        case proxy(ownerHostID: Host.ID)
        case keyboardInteractive(SSHKeyboardInteractiveChallenge)
        case passphrase(keyID: SSHKeyRef.ID)
    }

    public var id: UUID = UUID()
    public var createdAt: Date = .now
    public var invocationID: AgentToolInvocation.ID
    public var hostID: Host.ID
    public var displayName: String
    public var address: String
    public var mode: Mode
    public var selectedIdentityID: Identity.ID?
    public var username: String
    public var selectedKeyID: SSHKeyRef.ID?
    public var failureMessage: String?

    public var requiresPassphrase: Bool {
        if case .passphrase = mode { true } else { false }
    }

    public var securityKey: SecurityKeySigningRequest? {
        if case .securityKey(let request) = mode { request } else { nil }
    }

    public var keyboardInteractive: SSHKeyboardInteractiveChallenge? {
        if case .keyboardInteractive(let challenge) = mode { challenge } else { nil }
    }

    public var journeyPrompt: SSHAuthenticationPrompt {
        let target: SSHAuthenticationPrompt.Target
        switch mode {
        case .proxy(let ownerHostID): target = .proxy(ownerHostID: ownerHostID)
        default: target = .host
        }
        return SSHAuthenticationPrompt(
            host: Host(id: hostID, name: displayName, host: address),
            selectedIdentityID: selectedIdentityID,
            username: username,
            selectedKeyID: selectedKeyID,
            failureMessage: failureMessage,
            requiresPassphrase: requiresPassphrase,
            mode: failureMessage == nil ? .localIdentity : .serverChallenge,
            keyboardInteractive: keyboardInteractive, target: target, usernameOnly: mode == .tailscaleUsername
        )
    }

    public init(
        id: UUID = UUID(), createdAt: Date = .now, invocationID: AgentToolInvocation.ID, hostID: Host.ID,
        displayName: String, address: String, mode: Mode, selectedIdentityID: Identity.ID? = nil, username: String,
        selectedKeyID: SSHKeyRef.ID? = nil, failureMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.invocationID = invocationID
        self.hostID = hostID
        self.displayName = displayName
        self.address = address
        self.mode = mode
        self.selectedIdentityID = selectedIdentityID
        self.username = username
        self.selectedKeyID = selectedKeyID
        self.failureMessage = failureMessage
    }
}

nonisolated public struct AgentSSHAuthenticationAnswer: Hashable, Sendable {
    /// Existing identity when selected; nil means the inline Custom form.
    public var identityID: Identity.ID?
    public var identityName: String?
    public var username: String
    public var password: String?
    public var passphrase: String?
    public var keyID: SSHKeyRef.ID?
    /// Existing identities are bound; inline values create an Identity.
    public var save: Bool

    public init(
        identityID: Identity.ID? = nil, identityName: String? = nil, username: String, password: String? = nil,
        passphrase: String? = nil, keyID: SSHKeyRef.ID? = nil, save: Bool
    ) {
        self.identityID = identityID
        self.identityName = identityName
        self.username = username
        self.password = password
        self.passphrase = passphrase
        self.keyID = keyID
        self.save = save
    }
}

nonisolated public enum AgentSSHAuthenticationResponse: Hashable, Sendable {
    case securityKey(SecurityKeyAssertion)
    case securityKeyFailed(String)
    case submit(AgentSSHAuthenticationAnswer)
    case keyboardInteractive([String])
    case cancelled
}

/// A host-key checkpoint raised locally while an Agent Exec or SFTP transport
/// is being prepared. The observation is public SSH metadata; it is never
/// serialized into the model-facing transcript or a tool result.
nonisolated public struct AgentSSHHostKeyRequest: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var createdAt: Date = .now
    public var invocationID: AgentToolInvocation.ID
    public var hostID: Host.ID
    public var displayName: String
    public var address: String
    public var prompt: SSHHostKeyPrompt
    /// False for a pane-backed temporary target, which has no Known Hosts
    /// record to update. Its accepted key can only live for this connection.
    public var allowsPersistentTrust: Bool

    public init(
        id: UUID = UUID(), createdAt: Date = .now, invocationID: AgentToolInvocation.ID, hostID: Host.ID,
        displayName: String, address: String, prompt: SSHHostKeyPrompt, allowsPersistentTrust: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.invocationID = invocationID
        self.hostID = hostID
        self.displayName = displayName
        self.address = address
        self.prompt = prompt
        self.allowsPersistentTrust = allowsPersistentTrust
    }
}

nonisolated public enum AgentSSHHostKeyResponse: Hashable, Sendable {
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
nonisolated public struct AgentSSHInteraction: Sendable {
    public typealias Authenticating =
        @Sendable (AgentSSHAuthenticationRequest) async -> AgentSSHAuthenticationResponse
    public typealias HostKeyConfirming =
        @Sendable (AgentSSHHostKeyRequest) async -> AgentSSHHostKeyResponse

    public var allowsUserInteraction: Bool
    public var presentationContextID: UUID?
    public var authenticate: Authenticating
    public var confirmHostKey: HostKeyConfirming

    /// What a run that cannot ask anybody does: refuse, rather than connect with
    /// whatever is lying around.
    public static let unavailable = AgentSSHInteraction(
        allowsUserInteraction: false, authenticate: { _ in .cancelled }, confirmHostKey: { _ in .deny }
    )

    public func signSecurityKey(
        _ request: SecurityKeySigningRequest, invocationID: AgentToolInvocation.ID
    ) async throws -> SecurityKeyAssertion {
        guard allowsUserInteraction, request.allowsUserInteraction else { throw SSHInteractionRequired() }
        try Task.checkCancellation()
        let response = await authenticate(
            AgentSSHAuthenticationRequest(
                id: request.id, invocationID: invocationID, hostID: request.hostID,
                displayName: request.hostname, address: request.hostname, mode: .securityKey(request), username: ""))
        try Task.checkCancellation()
        switch response {
        case .securityKey(let assertion): return assertion
        case .securityKeyFailed(let message): throw SecurityKeySigningFailure(message: message)
        default: throw CancellationError()
        }
    }

    public func respondToChallenge(
        _ challenge: SSHKeyboardInteractiveChallenge, invocationID: AgentToolInvocation.ID
    ) async throws -> [String] {
        try Task.checkCancellation()
        let response = await authenticate(
            AgentSSHAuthenticationRequest(
                id: challenge.id, invocationID: invocationID, hostID: challenge.hostID,
                displayName: challenge.hostname, address: challenge.address,
                mode: .keyboardInteractive(challenge), username: challenge.username
            )
        )
        try Task.checkCancellation()
        guard case .keyboardInteractive(let answers) = response else { throw CancellationError() }
        return answers
    }

    public init(
        presentationContextID: UUID? = nil, allowsUserInteraction: Bool = true, authenticate: @escaping Authenticating,
        confirmHostKey: @escaping HostKeyConfirming
    ) {
        self.allowsUserInteraction = allowsUserInteraction
        self.presentationContextID = presentationContextID
        self.authenticate = authenticate
        self.confirmHostKey = confirmHostKey
    }
}

nonisolated extension AgentToolServiceKey where Service == AgentSSHInteraction {
    public static let sshInteraction = AgentToolServiceKey<AgentSSHInteraction>(
        "termind.ssh-interaction"
    )
}

nonisolated extension AgentToolExecutionContext {
    /// The SSH prompt for this run, or one that refuses everything.
    ///
    /// Falling back rather than throwing: a host that registered the SSH tools
    /// and forgot the service has a bug, and the honest outcome of that bug is a
    /// connection that could not be authorized — not a crash inside a tool call.
    public var sshInteraction: AgentSSHInteraction {
        services[.sshInteraction] ?? .unavailable
    }
}

private nonisolated struct SecurityKeySigningFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated extension AgentToolServiceKey where Service == Bool {
    public static let sshInterjectionEnabled = AgentToolServiceKey<Bool>("termind.ssh-interjection-enabled")
}
