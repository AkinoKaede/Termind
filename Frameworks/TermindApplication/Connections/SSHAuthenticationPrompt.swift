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
    public init(
        host: Host, selectedIdentityID: Identity.ID? = nil, username: String, selectedKeyID: SSHKeyRef.ID? = nil,
        failureMessage: String? = nil, requiresPassphrase: Bool = false, mode: Mode = .localIdentity,
        keyboardInteractive: SSHKeyboardInteractiveChallenge? = nil, target: Target = .host
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
    }

    public var isProxy: Bool {
        if case .proxy = target { true } else { false }
    }

}
