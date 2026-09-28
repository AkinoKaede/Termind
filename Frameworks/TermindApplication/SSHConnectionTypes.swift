import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SSHHostKeyObservation: Hashable, Sendable {
    public var hostname: String
    public var port: Int
    public var algorithm: SSHKeyAlgorithm
    public var fingerprint: String
    /// The legacy MD5 digest used only to validate provisional SSH/SFTP URI fingerprints.
    /// Persistent trust and user presentation continue to use `fingerprint` (SHA-256).
    public var legacyMD5Fingerprint: Data?

    public var identity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: algorithm, fingerprint: fingerprint)
    }
    public init(
        hostname: String, port: Int, algorithm: SSHKeyAlgorithm, fingerprint: String,
        legacyMD5Fingerprint: Data? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.legacyMD5Fingerprint = legacyMD5Fingerprint
    }

}

public nonisolated struct SSHHostKeyChallenge: Hashable, Sendable {
    public var hostID: Host.ID
    public var observation: SSHHostKeyObservation
    public var expectedHostKeys: Set<SSHHostKeyIdentity>
    /// A provisional out-of-band constraint matched this key. Persistent
    /// Known Hosts remains authoritative and the user must still approve
    /// first use before the key can be trusted.
    public var provisionalConstraintMatched: Bool

    public init(
        hostID: Host.ID, observation: SSHHostKeyObservation,
        expectedHostKeys: Set<SSHHostKeyIdentity>,
        provisionalConstraintMatched: Bool = false
    ) {
        self.hostID = hostID
        self.observation = observation
        self.expectedHostKeys = expectedHostKeys
        self.provisionalConstraintMatched = provisionalConstraintMatched
    }
}

/// An additional, provisional host-key constraint supplied out of band.
/// It can reject a handshake, but never creates or overrides Known Hosts trust.
public nonisolated struct SSHHostKeyConstraint: Hashable, Sendable {
    public enum Algorithm: String, Hashable, Sendable {
        case rsa = "ssh-rsa"
        case dsa = "ssh-dss"
    }

    public var algorithm: Algorithm
    public var legacyMD5: Data

    public init(algorithm: Algorithm, legacyMD5: Data) {
        self.algorithm = algorithm
        self.legacyMD5 = legacyMD5
    }

    public func matches(_ observation: SSHHostKeyObservation) -> Bool {
        let algorithmMatches =
            switch algorithm {
            case .rsa: observation.algorithm == .rsa
            case .dsa: false  // The transport deliberately does not negotiate ssh-dss.
            }
        guard algorithmMatches, let candidate = observation.legacyMD5Fingerprint,
            candidate.count == legacyMD5.count
        else { return false }
        return zip(candidate, legacyMD5).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public nonisolated enum SSHHostKeyDecision: Equatable, Sendable {
    case accept
    case reject
}

public typealias SSHHostKeyAuthorizer = @Sendable (SSHHostKeyChallenge) async throws -> SSHHostKeyDecision
public typealias SSHAdditionalConnectionRequestResolver = @MainActor @Sendable () throws -> SSHConnectionRequest

public nonisolated struct SSHAuthorizedKeyInstall: Hashable, Sendable {
    public var publicKey: String
    public var name: String

    public init(publicKey: String, name: String) {
        self.publicKey = publicKey
        self.name = name
    }
}

public nonisolated enum SSHHostTrustPolicy: Equatable, Sendable {
    case requireKnownHost
    case allowChallenge
}

/// Controls every authentication action that may require user presence,
/// including Termind forms, Touch ID, and device-password authorization.
public nonisolated enum SSHInteractionPolicy: Equatable, Sendable {
    case allowed
    case forbidden
}

/// A capability probe could not finish without user interaction. This is not cancellation.
public nonisolated struct SSHInteractionRequired: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? {
        String(localized: "This server requires interactive authentication.")
    }
}

/// A connection configuration plus the optional interaction that may authorize
/// an unknown or changed host key. A nil authorizer preserves strict behavior:
/// the connection must already contain a matching expected key.
public nonisolated struct SSHConnectionRequest: Sendable {
    public var configuration: SSHConnectionConfiguration
    public var agentForwarding: (any SSHAgentForwarding)?
    public var permitsAgentForwarding = true
    public var agentForwardingContextID: UUID?
    public var authorizeHostKey: SSHHostKeyAuthorizer?
    public var keyboardInteractive: SSHKeyboardInteractiveHandler?
    public var securityKeySigning: SecurityKeySigningHandler?
    public var interactionPolicy: SSHInteractionPolicy
    public var hostKeyConstraints: [Host.ID: SSHHostKeyConstraint]

    public init(
        configuration: SSHConnectionConfiguration,
        authorizeHostKey: SSHHostKeyAuthorizer? = nil,
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        securityKeySigning: SecurityKeySigningHandler? = nil,
        interactionPolicy: SSHInteractionPolicy = .allowed,
        hostKeyConstraints: [Host.ID: SSHHostKeyConstraint] = [:],
        agentForwardingContextID: UUID? = nil
    ) {
        self.configuration = configuration
        self.authorizeHostKey = authorizeHostKey
        self.keyboardInteractive = keyboardInteractive
        self.securityKeySigning = securityKeySigning
        self.interactionPolicy = interactionPolicy
        self.hostKeyConstraints = hostKeyConstraints
        self.agentForwardingContextID = agentForwardingContextID
    }

    public func withKeyboardInteractiveFallback(_ handler: SSHKeyboardInteractiveHandler?) -> Self {
        var request = self
        if request.interactionPolicy == .allowed, request.keyboardInteractive == nil {
            request.keyboardInteractive = handler
        }
        return request
    }

    /// Enforced at the transport boundary as well as by application adapters.
    public func enforcingInteractionPolicy() -> Self {
        guard interactionPolicy == .forbidden else { return self }
        var request = self
        request.configuration.credentials = request.configuration.credentials.map { $0.withoutInteraction }
        for index in request.configuration.jumps.indices {
            request.configuration.jumps[index].credentials =
                request.configuration.jumps[index].credentials.map { $0.withoutInteraction }
        }
        request.authorizeHostKey = { _ in throw SSHInteractionRequired() }
        request.keyboardInteractive = { challenge in
            guard challenge.prompts.isEmpty else { throw SSHInteractionRequired() }
            return []
        }
        return request
    }
}

nonisolated extension SSHCredentials {
    fileprivate var withoutInteraction: SSHCredentials {
        switch self {
        case .securityKey:
            return .interactionRequired
        case .privateKey(_, _, _, requiresPassphrase: true):
            clearSecrets()
            return .interactionRequired
        case .secureEnclave(_, _, requiresUserPresence: true):
            return .interactionRequired
        default:
            return self
        }
    }
}

public nonisolated struct SSHHandshakeFailure: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case peerClosed
        case receiveFailed
        case invalidIdentification
        case timedOut
        case other
    }

    public enum Phase: String, Hashable, Sendable {
        case identification
        case keyExchange
        case unknown
    }

    public var code: Int32
    public var systemError: Int32?
    public var kind: Kind
    public var phase: Phase
    public var elapsedMilliseconds: Int
    public var peer: String?

    public init(
        code: Int32, systemError: Int32?, kind: Kind? = nil, phase: Phase,
        elapsedMilliseconds: Int, peer: String?
    ) {
        self.code = code
        self.systemError = systemError
        self.kind = kind ?? Self.defaultKind(code: code, phase: phase)
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
        self.peer = peer
    }

    public var diagnosticDescription: String {
        var fields = ["libssh2 \(code)"]
        if let systemError { fields.append("errno \(systemError)") }
        if let peer { fields.append("peer \(peer)") }
        fields.append("\(elapsedMilliseconds) ms")
        return fields.joined(separator: ", ")
    }

    public var localizedDescription: String {
        let message: String
        switch kind {
        case .peerClosed:
            message = String(
                localized:
                    "The server closed the connection before sending its SSH identification."
            )
        case .receiveFailed:
            message = String(
                localized:
                    "The SSH identification could not be read. The server or network path may have reset the connection."
            )
        case .invalidIdentification:
            message = String(localized: "The server sent an invalid SSH identification.")
        case .timedOut:
            message = String(localized: "The SSH handshake timed out.")
        case .other:
            message = String(localized: "The SSH handshake failed.")
        }
        return "\(message) [\(diagnosticDescription)]"
    }

    private static func defaultKind(code: Int32, phase: Phase) -> Kind {
        switch (phase, code) {
        case (.identification, -13): .peerClosed
        case (.identification, -43): .receiveFailed
        case (.identification, -2): .invalidIdentification
        case (_, -9), (_, -30): .timedOut
        default: .other
        }
    }
}

public nonisolated struct SSHHostKeyPrompt: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case firstUse
        case additionalKey(trustedKeyCount: Int)
    }

    public var observation: SSHHostKeyObservation
    public var kind: Kind
    public var uriFingerprintMatched: Bool
    public init(
        observation: SSHHostKeyObservation, kind: Kind,
        uriFingerprintMatched: Bool = false
    ) {
        self.observation = observation
        self.kind = kind
        self.uriFingerprintMatched = uriFingerprintMatched
    }

    public init(challenge: SSHHostKeyChallenge) {
        self.init(
            observation: challenge.observation,
            kind: challenge.expectedHostKeys.isEmpty
                ? .firstUse
                : .additionalKey(trustedKeyCount: challenge.expectedHostKeys.count),
            uriFingerprintMatched: challenge.provisionalConstraintMatched
        )
    }

}

public nonisolated enum SSHCredentials: Sendable {
    case securityKey(SecurityKeyCredential, name: String = "Security Key")
    case password(SSHSecret)
    case privateKey(
        privateKey: SSHSecret, publicKey: String?, passphrase: SSHSecret?,
        requiresPassphrase: Bool = false
    )
    case secureEnclave(
        credential: SecureEnclaveKeyCredential, publicKey: String,
        requiresUserPresence: Bool = false
    )
    /// A public-key credential exists, but the current policy may not obtain it
    /// without presenting Touch ID, a device-password prompt, or a passphrase form.
    case interactionRequired

    public static func password(_ value: String) -> Self {
        .password(SSHSecret(value))
    }

    public static func privateKey(
        privateKey: String, publicKey: String?, passphrase: String?,
        requiresPassphrase: Bool = false
    ) -> Self {
        .privateKey(
            privateKey: SSHSecret(privateKey), publicKey: publicKey,
            passphrase: passphrase.map(SSHSecret.init),
            requiresPassphrase: requiresPassphrase
        )
    }

    public func clearSecrets() {
        switch self {
        case .password(let password):
            password.clear()
        case .privateKey(let privateKey, _, let passphrase, _):
            privateKey.clear()
            passphrase?.clear()
        case .securityKey, .secureEnclave, .interactionRequired:
            break
        }
    }
}

public nonisolated enum SSHResolvedKeyCredential: Sendable {
    case securityKey(SecurityKeyCredential)
    case software(SSHSecret, passphrase: SSHSecret? = nil)
    case secureEnclave(SecureEnclaveKeyCredential)

    public var hasSavedPassphrase: Bool {
        if case .software(_, let passphrase) = self { return passphrase != nil && passphrase?.isConsumed == false }
        return false
    }

    public func clearSecrets() {
        if case .software(let privateKey, let passphrase) = self {
            privateKey.clear()
            passphrase?.clear()
        }
    }

    public func sshCredential(for key: SSHKeyRef, passphraseOverride: SSHSecret? = nil) -> SSHCredentials {
        sshCredential(
            publicKey: key.publicKey, certificate: key.certificate, passphraseOverride: passphraseOverride,
            requiresPassphrase: key.requiresPassphraseEntry,
            requiresUserPresence: key.requiresUserPresence, keyName: key.label)
    }

    public func sshCredential(
        publicKey: String, certificate: String = "", passphraseOverride: SSHSecret? = nil,
        requiresPassphrase: Bool = false, requiresUserPresence: Bool = false, keyName: String = "Security Key"
    ) -> SSHCredentials {
        switch self {
        case .securityKey(let key): return .securityKey(key, name: keyName)
        case .software(let privateKey, let savedPassphrase):
            let hasSavedPassphrase = self.hasSavedPassphrase
            if let passphraseOverride, savedPassphrase !== passphraseOverride { savedPassphrase?.clear() }
            return .privateKey(
                privateKey: privateKey,
                publicKey: certificate.isEmpty
                    ? (publicKey.isEmpty ? nil : publicKey)
                    : certificate,
                passphrase: passphraseOverride ?? savedPassphrase,
                requiresPassphrase: requiresPassphrase && !hasSavedPassphrase
            )
        case .secureEnclave(let credential):
            return .secureEnclave(
                credential: credential, publicKey: publicKey,
                requiresUserPresence: requiresUserPresence
            )
        }
    }
}

nonisolated extension StoredSSHKeyCredential {
    public func resolvedCredential() -> SSHResolvedKeyCredential {
        switch self {
        case .software(let secret):
            .software(SSHSecret(secret.privateKey), passphrase: secret.passphrase.map(SSHSecret.init))
        case .secureEnclave(let key): .secureEnclave(key)
        }
    }

    public func sshCredential(
        publicKey: String, certificate: String = "", passphraseOverride: SSHSecret? = nil,
        requiresPassphrase: Bool = false, requiresUserPresence: Bool = false
    ) -> SSHCredentials {
        switch self {
        case .software(let secret):
            SSHResolvedKeyCredential.software(
                SSHSecret(secret.privateKey), passphrase: secret.passphrase.map(SSHSecret.init)
            ).sshCredential(
                publicKey: publicKey, certificate: certificate,
                passphraseOverride: passphraseOverride,
                requiresPassphrase: requiresPassphrase,
                requiresUserPresence: requiresUserPresence
            )
        case .secureEnclave(let credential):
            SSHResolvedKeyCredential.secureEnclave(credential).sshCredential(
                publicKey: publicKey, certificate: certificate,
                passphraseOverride: passphraseOverride,
                requiresPassphrase: requiresPassphrase,
                requiresUserPresence: requiresUserPresence
            )
        }
    }
}

/// Non-secret provenance retained by a live connection so its reusable
/// additional-connection snapshot can resolve current credentials by ID.
public nonisolated struct SSHAuthenticationReference: Hashable, Sendable {
    public var identityID: Identity.ID?
    /// Used only when no Identity owns this login. An Identity always resolves
    /// its current Key, so changing the Identity updates later connections.
    public var fallbackKeyID: SSHKeyRef.ID?
    /// Used only when there is no Identity. Identity-owned logins always use
    /// the Identity's current username.
    public var username: String
    public var permitsNone: Bool
    public var hasEphemeralSecret: Bool

    public init(
        identityID: Identity.ID? = nil, fallbackKeyID: SSHKeyRef.ID? = nil,
        username: String = "",
        permitsNone: Bool = false, hasEphemeralSecret: Bool = false
    ) {
        self.identityID = identityID
        self.fallbackKeyID = fallbackKeyID
        self.username = username
        self.permitsNone = permitsNone
        self.hasEphemeralSecret = hasEphemeralSecret
    }
}

public nonisolated struct SSHConnectionConfiguration: Sendable {
    public var hostID: Host.ID
    public var host: String
    public var port: Int
    public var username: String
    public var credentials: [SSHCredentials]
    public var expectedHostKeys: Set<SSHHostKeyIdentity>
    public var proxy: SSHTransportProxy?
    public var jumps: [SSHRouteHopConfiguration] = []
    public var charset: RemoteCharset
    public var authenticationReference: SSHAuthenticationReference
    public init(
        hostID: Host.ID, host: String, port: Int, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>, proxy: SSHTransportProxy? = nil,
        jumps: [SSHRouteHopConfiguration] = [],
        charset: RemoteCharset = .utf8,
        authenticationReference: SSHAuthenticationReference? = nil
    ) {
        self.hostID = hostID
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.expectedHostKeys = expectedHostKeys
        self.proxy = proxy
        self.jumps = jumps
        self.charset = charset
        self.authenticationReference =
            authenticationReference
            ?? SSHAuthenticationReference(
                username: username,
                permitsNone: credentials.isEmpty,
                hasEphemeralSecret: !credentials.isEmpty
            )
    }

    /// Invalidates every authentication secret shared by copies of this
    /// one-shot configuration. Network and provenance fields remain readable.
    public func clearSecrets() {
        for credential in credentials { credential.clearSecrets() }
        proxy?.clearSecret()
        for jump in jumps { jump.clearSecrets() }
    }

}

public nonisolated struct SSHCredentialResolution: Sendable {
    public var credentials: [SSHCredentials]
    public var failures: [String]
    public var hasConfiguredCredential: Bool
    public var requiredPassphraseKeyID: SSHKeyRef.ID?
    public init(
        credentials: [SSHCredentials], failures: [String], hasConfiguredCredential: Bool,
        requiredPassphraseKeyID: SSHKeyRef.ID? = nil
    ) {
        self.credentials = credentials
        self.failures = failures
        self.hasConfiguredCredential = hasConfiguredCredential
        self.requiredPassphraseKeyID = requiredPassphraseKeyID
    }

}

public nonisolated enum TermindSSHError: LocalizedError, Sendable {
    case socket(String)
    case proxy(String)
    case proxyAuthentication(hostID: Host.ID, serverChallenge: Bool, message: String)
    case route(String)
    case routeHost(
        hostID: Host.ID, authentication: Bool, serverChallenge: Bool,
        hostKey: Bool, message: String
    )
    case library(String)
    case handshake(SSHHandshakeFailure)
    case authenticationFailed(String)
    case hostKeyChanged(expected: [String], received: String)
    case missingCredential
    case keyPassphraseRequired
    case missingUsername
    case untrustedHost
    case mismatchedHostKey
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .socket(let message), .proxy(let message), .route(let message),
            .library(let message), .authenticationFailed(let message):
            message
        case .proxyAuthentication(_, _, let message): message
        case .handshake(let failure): failure.localizedDescription
        case .routeHost(_, _, _, _, let message): message
        case .hostKeyChanged(let expected, let received):
            String(
                localized:
                    "The host key changed. Expected one of \(expected.joined(separator: ", ")), received \(received).")
        case .missingCredential: String(localized: "The selected identity has no usable password or private key.")
        case .keyPassphraseRequired: String(localized: "Enter the Passphrase for the selected key.")
        case .missingUsername: String(localized: "The selected host has no login username.")
        case .untrustedHost: String(localized: "Connect to this host once before exporting a key to it.")
        case .mismatchedHostKey: String(localized: "The saved host key no longer matches this host.")
        case .disconnected: String(localized: "The SSH connection closed.")
        }
    }

    public var shouldRequestAuthentication: Bool {
        if case .proxyAuthentication = self { return true }
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, let authentication, _, _, _) = self { return authentication }
        return false
    }

    public var isLocalAuthenticationRequirement: Bool {
        switch self {
        case .missingCredential, .keyPassphraseRequired, .missingUsername: true
        case .proxyAuthentication(_, let serverChallenge, _): !serverChallenge
        default: false
        }
    }

    public var isServerAuthenticationChallenge: Bool {
        if case .proxyAuthentication(_, let serverChallenge, _) = self { return serverChallenge }
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, _, let serverChallenge, _, _) = self { return serverChallenge }
        return false
    }

    public var routeHostID: Host.ID? {
        if case .proxyAuthentication(let id, _, _) = self { return id }
        guard case .routeHost(let id, _, _, _, _) = self else { return nil }
        return id
    }

    public var isProxyAuthentication: Bool {
        if case .proxyAuthentication = self { true } else { false }
    }

    public var shouldRequestHostKey: Bool {
        guard case .routeHost(_, _, _, let hostKey, _) = self else { return false }
        return hostKey
    }

    public var isHostKeyChanged: Bool {
        if case .hostKeyChanged = self { return true }
        return false
    }

}
