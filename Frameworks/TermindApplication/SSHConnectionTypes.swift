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
        case .socket, .library, .disconnected: true
        case .proxy, .route, .routeHost, .authenticationFailed, .hostKeyChanged,
            .missingCredential, .keyPassphraseRequired, .missingUsername,
            .untrustedHost, .mismatchedHostKey:
            false
        }
    }
}
