import Foundation

nonisolated struct SSHHostKeyObservation: Hashable, Sendable {
    var hostname: String
    var port: Int
    var algorithm: SSHKeyAlgorithm
    var fingerprint: String

    var identity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: algorithm, fingerprint: fingerprint)
    }
}

nonisolated struct SSHHostKeyPrompt: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case firstUse
        case additionalKey(trustedKeyCount: Int)
    }

    var observation: SSHHostKeyObservation
    var kind: Kind
}

nonisolated enum SSHCredentials: Sendable {
    case password(String)
    case privateKey(privateKey: String, publicKey: String?, passphrase: String?)
    case secureEnclave(credential: SecureEnclaveKeyCredential, publicKey: String)
}

nonisolated extension StoredSSHKeyCredential {
    func sshCredential(
        publicKey: String, certificate: String = "", passphraseOverride: String? = nil
    ) -> SSHCredentials {
        switch self {
        case .software(let secret):
            .privateKey(
                privateKey: secret.privateKey,
                publicKey: certificate.isEmpty
                    ? (publicKey.isEmpty ? nil : publicKey)
                    : certificate,
                passphrase: passphraseOverride ?? secret.passphrase
            )
        case .secureEnclave(let credential):
            .secureEnclave(credential: credential, publicKey: publicKey)
        }
    }
}

nonisolated struct SSHConnectionConfiguration: Sendable {
    var hostID: Host.ID
    var host: String
    var port: Int
    var username: String
    var credentials: [SSHCredentials]
    var expectedHostKeys: Set<SSHHostKeyIdentity>
    var proxy: SSHTransportProxy?
    var jumps: [SSHRouteHopConfiguration] = []
}

nonisolated struct SSHCredentialResolution: Sendable {
    var credentials: [SSHCredentials]
    var failures: [String]
    var hasConfiguredCredential: Bool
    var requiredPassphraseKeyID: SSHKeyRef.ID?
}

nonisolated enum TermindSSHError: LocalizedError, Sendable {
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

    var errorDescription: String? {
        switch self {
        case .socket(let message), .proxy(let message), .route(let message),
            .library(let message), .authenticationFailed(let message): message
        case .routeHost(_, _, _, _, let message): message
        case .hostKeyChanged(let expected, let received):
            String(localized: "The host key changed. Expected one of \(expected.joined(separator: ", ")), received \(received).")
        case .missingCredential: String(localized: "The selected identity has no usable password or private key.")
        case .keyPassphraseRequired: String(localized: "Enter the Passphrase for the selected key.")
        case .missingUsername: String(localized: "The selected host has no login username.")
        case .untrustedHost: String(localized: "Connect to this host once before exporting a key to it.")
        case .mismatchedHostKey: String(localized: "The saved host key no longer matches this host.")
        case .disconnected: String(localized: "The SSH connection closed.")
        }
    }

    var shouldRequestAuthentication: Bool {
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, let authentication, _, _, _) = self { return authentication }
        return false
    }

    var isLocalAuthenticationRequirement: Bool {
        switch self {
        case .missingCredential, .keyPassphraseRequired, .missingUsername: true
        default: false
        }
    }

    var isServerAuthenticationChallenge: Bool {
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, _, let serverChallenge, _, _) = self { return serverChallenge }
        return false
    }

    var routeHostID: Host.ID? {
        guard case .routeHost(let id, _, _, _, _) = self else { return nil }
        return id
    }

    var shouldRequestHostKey: Bool {
        guard case .routeHost(_, _, _, let hostKey, _) = self else { return false }
        return hostKey
    }

    var isHostKeyChanged: Bool {
        if case .hostKeyChanged = self { return true }
        return false
    }

    var isRetryableForwardingFailure: Bool {
        switch self {
        case .socket, .library, .disconnected: true
        case .proxy, .route, .routeHost, .authenticationFailed, .hostKeyChanged,
            .missingCredential, .keyPassphraseRequired, .missingUsername,
            .untrustedHost, .mismatchedHostKey: false
        }
    }
}
