import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SSHHostKeyObservation: Hashable, Sendable {
    public var hostname: String
    public var port: Int
    public var algorithm: SSHKeyAlgorithm
    public var fingerprint: String

    public var identity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: algorithm, fingerprint: fingerprint)
    }
    public init(hostname: String, port: Int, algorithm: SSHKeyAlgorithm, fingerprint: String) {
        self.hostname = hostname
        self.port = port
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }

}

public nonisolated struct SSHHostKeyChallenge: Hashable, Sendable {
    public var hostID: Host.ID
    public var observation: SSHHostKeyObservation
    public var expectedHostKeys: Set<SSHHostKeyIdentity>

    public init(
        hostID: Host.ID, observation: SSHHostKeyObservation,
        expectedHostKeys: Set<SSHHostKeyIdentity>
    ) {
        self.hostID = hostID
        self.observation = observation
        self.expectedHostKeys = expectedHostKeys
    }
}

public nonisolated enum SSHHostKeyDecision: Equatable, Sendable {
    case accept
    case reject
}

public typealias SSHHostKeyAuthorizer = @Sendable (SSHHostKeyChallenge) async throws -> SSHHostKeyDecision

public nonisolated enum SSHHostTrustPolicy: Equatable, Sendable {
    case requireKnownHost
    case allowChallenge
}

/// Controls Termind authentication forms. System key authorization (Touch ID) remains allowed.
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
    public var authorizeHostKey: SSHHostKeyAuthorizer?
    public var keyboardInteractive: SSHKeyboardInteractiveHandler?
    public var interactionPolicy: SSHInteractionPolicy

    public init(
        configuration: SSHConnectionConfiguration,
        authorizeHostKey: SSHHostKeyAuthorizer? = nil,
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        interactionPolicy: SSHInteractionPolicy = .allowed
    ) {
        self.configuration = configuration
        self.authorizeHostKey = authorizeHostKey
        self.keyboardInteractive = keyboardInteractive
        self.interactionPolicy = interactionPolicy
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
        request.authorizeHostKey = { _ in throw SSHInteractionRequired() }
        request.keyboardInteractive = { challenge in
            guard challenge.prompts.isEmpty else { throw SSHInteractionRequired() }
            return []
        }
        return request
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
    public init(observation: SSHHostKeyObservation, kind: Kind) {
        self.observation = observation
        self.kind = kind
    }

}

public nonisolated enum SSHCredentials: Sendable {
    case password(String)
    case privateKey(privateKey: String, publicKey: String?, passphrase: String?)
    case secureEnclave(credential: SecureEnclaveKeyCredential, publicKey: String)
}

nonisolated extension StoredSSHKeyCredential {
    public func sshCredential(
        publicKey: String, certificate: String = "", passphraseOverride: String? = nil
    ) -> SSHCredentials {
        switch self {
        case .software(let secret):
            .privateKey(
                privateKey: secret.privateKey,
                publicKey: certificate.isEmpty
                    ? (publicKey.isEmpty ? nil : publicKey)
                    : certificate,
                passphrase: passphraseOverride
            )
        case .secureEnclave(let credential):
            .secureEnclave(credential: credential, publicKey: publicKey)
        }
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
    public init(
        hostID: Host.ID, host: String, port: Int, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>, proxy: SSHTransportProxy? = nil,
        jumps: [SSHRouteHopConfiguration] = []
    ) {
        self.hostID = hostID
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.expectedHostKeys = expectedHostKeys
        self.proxy = proxy
        self.jumps = jumps
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
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, let authentication, _, _, _) = self { return authentication }
        return false
    }

    public var isLocalAuthenticationRequirement: Bool {
        switch self {
        case .missingCredential, .keyPassphraseRequired, .missingUsername: true
        default: false
        }
    }

    public var isServerAuthenticationChallenge: Bool {
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, _, let serverChallenge, _, _) = self { return serverChallenge }
        return false
    }

    public var routeHostID: Host.ID? {
        guard case .routeHost(let id, _, _, _, _) = self else { return nil }
        return id
    }

    public var shouldRequestHostKey: Bool {
        guard case .routeHost(_, _, _, let hostKey, _) = self else { return false }
        return hostKey
    }

    public var isHostKeyChanged: Bool {
        if case .hostKeyChanged = self { return true }
        return false
    }

    public var isRetryableForwardingFailure: Bool {
        switch self {
        case .socket, .library, .handshake, .disconnected: true
        case .proxy, .route, .routeHost, .authenticationFailed, .hostKeyChanged,
            .missingCredential, .keyPassphraseRequired, .missingUsername,
            .untrustedHost, .mismatchedHostKey:
            false
        }
    }
}
