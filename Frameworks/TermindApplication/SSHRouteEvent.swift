import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated enum SSHRouteEvent: Hashable, Sendable {
    case connecting(Host.ID)
    case authenticating(Host.ID)
    case authenticated(Host.ID)
    case connected(Host.ID)
    case initializing(Host.ID, String)
}

public typealias SSHRouteProgressHandler = @Sendable (SSHRouteEvent) -> Void

public nonisolated struct SSHAuthenticationSubmission: Hashable, Sendable {
    public var username: String
    public var password: String?
    public var passphrase: String?
    public var keyID: SSHKeyRef.ID?
    public var identityID: Identity.ID? = nil
    public var requiresPasswordReentry = false
    public var requiresPassphraseReentry = false
    public init(
        username: String, password: String? = nil, passphrase: String? = nil, keyID: SSHKeyRef.ID? = nil,
        identityID: Identity.ID? = nil
    ) {
        self.username = username
        self.password = password
        self.passphrase = passphrase
        self.keyID = keyID
        self.identityID = identityID
    }

    public mutating func clearSecrets() {
        if password != nil { requiresPasswordReentry = true }
        if passphrase != nil { requiresPassphraseReentry = true }
        password = nil
        passphrase = nil
    }

}

nonisolated extension Dictionary where Value == SSHAuthenticationSubmission {
    /// Moves plaintext answers into one connection attempt while leaving only
    /// non-secret selection metadata in the session's retry state.
    public mutating func takeAuthenticationSecrets() -> Self {
        let result = self
        for key in keys {
            self[key]?.clearSecrets()
        }
        return result
    }
}
