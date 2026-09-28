import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SSHAuthenticationPrompt: Identifiable, Hashable, Sendable {
    public nonisolated enum Target: Hashable, Sendable {
        case host
        case proxy(ownerHostID: Host.ID)
    }

    public nonisolated enum Mode: Hashable, Sendable {
        case localIdentity
        case serverChallenge
    }

    public let id = UUID()
    public var host: Host
    public var selectedIdentityID: Identity.ID? = nil
    public var username: String
    public var selectedKeyID: SSHKeyRef.ID?
    public var failureMessage: String?
    public var keyboardInteractive: SSHKeyboardInteractiveChallenge?
    public var requiresPassphrase = false
    public var mode: Mode = .localIdentity
    public var target: Target = .host
    public var allowsSaving = true
    public init(
        host: Host, selectedIdentityID: Identity.ID? = nil, username: String, selectedKeyID: SSHKeyRef.ID? = nil,
        failureMessage: String? = nil, requiresPassphrase: Bool = false, mode: Mode = .localIdentity,
        keyboardInteractive: SSHKeyboardInteractiveChallenge? = nil, target: Target = .host,
        allowsSaving: Bool = true
    ) {
        self.host = host
        self.selectedIdentityID = selectedIdentityID
        self.username = username
        self.selectedKeyID = selectedKeyID
        self.failureMessage = failureMessage
        self.requiresPassphrase = requiresPassphrase
        self.mode = mode
        self.keyboardInteractive = keyboardInteractive
        self.target = target
        self.allowsSaving = allowsSaving
    }

    public var isProxy: Bool {
        if case .proxy = target { true } else { false }
    }

}

/// Shared projection from route metadata and staged submissions into the
/// presentation-only authentication prompt. Connection lifetimes, retries,
/// and credential persistence remain owned by each feature.
@MainActor
public enum SSHAuthenticationPromptResolver {
    public static func host(
        _ host: Host, using store: any RemoteSessionHostStore,
        submission: SSHAuthenticationSubmission? = nil,
        username: String? = nil, selectedKeyID: SSHKeyRef.ID? = nil,
        failureMessage: String? = nil,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity,
        requiresPassphrase: Bool? = nil, allowsSaving: Bool = true
    ) -> SSHAuthenticationPrompt {
        let identity = submission?.identityID.flatMap(store.identity) ?? store.identity(for: host)
        let keyID = selectedKeyID ?? submission?.keyID ?? identity?.keyID
        let resolvedUsername = username ?? submission?.username ?? identity?.username ?? ""
        let needsPassphrase =
            requiresPassphrase
            ?? (submission?.requiresPasswordReentry != true
                && keyID.flatMap(store.key).map {
                    (mode == .serverChallenge && $0.hasPassphrase) || store.requiresPassphraseEntry(for: $0)
                } == true
                && submission?.passphrase == nil)
        return SSHAuthenticationPrompt(
            host: host, selectedIdentityID: submission?.identityID ?? identity?.id,
            username: resolvedUsername, selectedKeyID: keyID,
            failureMessage: failureMessage?.isEmpty == false ? failureMessage : nil,
            requiresPassphrase: needsPassphrase, mode: mode,
            allowsSaving: allowsSaving)
    }

    public static func proxy(
        for owner: Host, using store: any RemoteSessionHostStore,
        submission: SSHProxyAuthenticationSubmission? = nil,
        failureMessage: String? = nil,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity,
        allowsSaving: Bool = true
    ) -> SSHAuthenticationPrompt? {
        guard let proxy = owner.proxy else { return nil }
        let configured = (submission?.identityID ?? proxy.identityID).flatMap(store.identity)
        let selected: Identity?
        if let configured {
            switch store.passwordAvailability(for: configured) {
            case .available, .notConfigured: selected = configured
            case .missing, .failed: selected = nil
            }
        } else {
            selected = nil
        }
        return SSHAuthenticationPrompt(
            host: Host(
                id: owner.id, name: String(localized: "Proxy for \(owner.name)"),
                host: proxy.hostname, port: proxy.port),
            selectedIdentityID: selected?.id,
            username: submission?.username ?? proxy.username,
            failureMessage: failureMessage, mode: mode,
            target: .proxy(ownerHostID: owner.id), allowsSaving: allowsSaving)
    }
}
