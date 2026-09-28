import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated enum SSHRouteEvent: Hashable, Sendable {
    case proxyConnecting(Host.ID)
    case proxyConnected(Host.ID)
    case connecting(Host.ID)
    case authenticating(Host.ID)
    case authenticated(Host.ID)
    case connected(Host.ID)
    case initializing(Host.ID, String)
}

public typealias SSHRouteProgressHandler = @Sendable (SSHRouteEvent) -> Void

public nonisolated struct SSHAuthenticationSubmission: Sendable {
    public var username: String
    public var password: String?
    public var passphrase: String?
    public var keyID: SSHKeyRef.ID?
    public var identityID: Identity.ID? = nil
    public var requiresPasswordReentry = false
    public var requiresPassphraseReentry = false
    private var runtimePassword: SSHSecret?
    private var runtimePassphrase: SSHSecret?
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

    public var hasPassword: Bool { password != nil || runtimePassword != nil }
    public var hasPassphrase: Bool {
        passphrase?.isEmpty == false || runtimePassphrase != nil
    }

    public func passwordForConnection() -> SSHSecret? {
        runtimePassword ?? password.map(SSHSecret.init)
    }

    public func passphraseForConnection() -> SSHSecret? {
        runtimePassphrase ?? passphrase.map(SSHSecret.init)
    }

    public mutating func clearSecrets() {
        if hasPassword { requiresPasswordReentry = true }
        if hasPassphrase { requiresPassphraseReentry = true }
        password = nil
        passphrase = nil
        runtimePassword?.clear()
        runtimePassword = nil
        runtimePassphrase?.clear()
        runtimePassphrase = nil
    }

    fileprivate mutating func prepareForConnectionAttempt() {
        if let password {
            runtimePassword = SSHSecret(password)
            self.password = nil
        }
        if let passphrase {
            if !passphrase.isEmpty {
                runtimePassphrase = SSHSecret(passphrase)
            }
            self.passphrase = nil
        }
    }

}

public nonisolated struct SSHProxyAuthenticationSubmission: Sendable {
    public var username: String
    public var password: String?
    public var identityID: Identity.ID?
    public var requiresPasswordReentry = false
    private var runtimePassword: SSHSecret?

    public init(username: String, password: String? = nil, identityID: Identity.ID? = nil) {
        self.username = username
        self.password = password
        self.identityID = identityID
    }

    public var hasPassword: Bool { password != nil || runtimePassword != nil }
    public func passwordForConnection() -> SSHSecret? { runtimePassword ?? password.map(SSHSecret.init) }

    public mutating func clearSecrets() {
        if hasPassword { requiresPasswordReentry = true }
        password = nil
        runtimePassword?.clear()
        runtimePassword = nil
    }

    fileprivate mutating func prepareForConnectionAttempt() {
        if let password {
            runtimePassword = SSHSecret(password)
            self.password = nil
        }
    }
}

nonisolated extension Dictionary where Key == Host.ID, Value == SSHProxyAuthenticationSubmission {
    public func firstHostRequiringProxyPassword(in route: [Host]) -> Host? {
        route.first { self[$0.id]?.requiresPasswordReentry == true }
    }

    public mutating func takeProxyAuthenticationSecrets() -> Self {
        var result: Self = [:]
        for key in Array(keys) {
            guard var retained = self[key] else { continue }
            var attempt = retained
            attempt.prepareForConnectionAttempt()
            retained.clearSecrets()
            self[key] = retained
            result[key] = attempt
        }
        return result
    }
}

nonisolated extension Dictionary where Key == Host.ID, Value == SSHAuthenticationSubmission {
    public func firstHostRequiringPassword(in route: [Host]) -> Host? {
        route.first { self[$0.id]?.requiresPasswordReentry == true }
    }

    public func firstHostRequiringPassphrase(
        in route: [Host], key: (SSHKeyRef.ID) -> SSHKeyRef?,
        requiresEntry: (SSHKeyRef) -> Bool = { $0.requiresPassphraseEntry }
    ) -> Host? {
        route.first { host in
            guard let submission = self[host.id], !submission.hasPassphrase,
                let keyID = submission.keyID
            else { return false }
            return key(keyID).map(requiresEntry) == true
        }
    }

    /// Moves plaintext answers into one connection attempt while leaving only
    /// non-secret selection metadata in the session's retry state.
    public mutating func takeAuthenticationSecrets() -> Self {
        var result: Self = [:]
        for key in Array(keys) {
            guard var retained = self[key] else { continue }
            var attempt = retained
            attempt.prepareForConnectionAttempt()
            retained.clearSecrets()
            self[key] = retained
            result[key] = attempt
        }
        return result
    }
}
