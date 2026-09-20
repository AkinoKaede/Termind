import Foundation
import TermindDomain

import struct TermindDomain.Host

public typealias SSHCredentialAccessHandler = @Sendable (Set<Identity.ID>, Date) -> Void

/// A value snapshot taken on MainActor. Resolving Keychain references can block and
/// therefore happens on a detached worker, before any SSH transport is opened.
public nonisolated struct SSHConnectionPreparation: Sendable {
    public struct Node: Sendable {
        public var host: Host
        public var identity: Identity?
        public var key: SSHKeyRef?
        public var submission: SSHAuthenticationSubmission?
        public var trustedKeys: Set<SSHHostKeyIdentity>
        public var proxyIdentity: Identity?
        public init(
            host: Host, identity: Identity?, key: SSHKeyRef?, submission: SSHAuthenticationSubmission?,
            trustedKeys: Set<SSHHostKeyIdentity>, proxyIdentity: Identity?
        ) {
            self.host = host
            self.identity = identity
            self.key = key
            self.submission = submission
            self.trustedKeys = trustedKeys
            self.proxyIdentity = proxyIdentity
        }

    }
    public var nodes: [Node]
    public var secrets: any SecretStoring
    public var credentialAccessHandler: SSHCredentialAccessHandler?

    public func resolve(
        discoveryOnly: Bool = false,
        trustPolicy: SSHHostTrustPolicy = .requireKnownHost
    ) async throws -> SSHConnectionConfiguration {
        let task = Task.detached {
            try resolveSynchronously(
                discoveryOnly: discoveryOnly,
                trustPolicy: trustPolicy
            )
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveSynchronously(
        discoveryOnly: Bool, trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHConnectionConfiguration {
        var accessedIdentityIDs: Set<Identity.ID> = []
        defer {
            if !accessedIdentityIDs.isEmpty {
                credentialAccessHandler?(accessedIdentityIDs, Date())
            }
        }
        guard let target = nodes.last else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        var jumps: [SSHRouteHopConfiguration] = []
        for (offset, node) in nodes.dropLast().enumerated() {
            do {
                try Task.checkCancellation()
                let material = try credentials(node, accessedIdentityIDs: &accessedIdentityIDs)
                if trustPolicy == .requireKnownHost, node.trustedKeys.isEmpty {
                    throw TermindSSHError.untrustedHost
                }
                jumps.append(
                    SSHRouteHopConfiguration(
                        id: node.host.id, name: node.host.name, host: node.host.host, port: node.host.port,
                        username: material.0, credentials: material.1,
                        expectedHostKeys: node.trustedKeys,
                        proxy: try proxy(node, accessedIdentityIDs: &accessedIdentityIDs),
                        authenticationReference: authenticationReference(for: node)
                    ))
            } catch {
                if error is CancellationError { throw error }
                let ssh = error as? TermindSSHError
                throw TermindSSHError.routeHost(
                    hostID: node.host.id, authentication: ssh?.isLocalAuthenticationRequirement == true,
                    serverChallenge: false, hostKey: isUntrusted(ssh),
                    message: String(
                        localized: "Jump Host \(offset + 1) (\(node.host.name)): \(error.localizedDescription)")
                )
            }
        }
        try Task.checkCancellation()
        let material =
            discoveryOnly
            ? ("", [SSHCredentials]())
            : try credentials(target, accessedIdentityIDs: &accessedIdentityIDs)
        if !discoveryOnly, trustPolicy == .requireKnownHost, target.trustedKeys.isEmpty {
            throw TermindSSHError.untrustedHost
        }
        return SSHConnectionConfiguration(
            hostID: target.host.id, host: target.host.host, port: target.host.port,
            username: material.0, credentials: material.1, expectedHostKeys: target.trustedKeys,
            proxy: try proxy(target, accessedIdentityIDs: &accessedIdentityIDs), jumps: jumps,
            authenticationReference: authenticationReference(for: target)
        )
    }

    private func authenticationReference(for node: Node) -> SSHAuthenticationReference {
        if let identity = connectionIdentity(for: node) {
            return SSHAuthenticationReference(
                identityID: identity.id,
                username: identity.username,
                permitsNone: !identity.hasSecret,
                hasEphemeralSecret: node.submission?.password != nil || node.submission?.passphrase != nil
            )
        }
        return SSHAuthenticationReference(
            fallbackKeyID: node.submission?.keyID ?? node.key?.id,
            username: node.submission?.username ?? "",
            permitsNone: node.key == nil && node.submission?.password == nil,
            hasEphemeralSecret: node.submission?.password != nil || node.submission?.passphrase != nil
        )
    }

    private func credentials(
        _ node: Node, accessedIdentityIDs: inout Set<Identity.ID>
    ) throws -> (String, [SSHCredentials]) {
        let username = (node.submission?.username ?? node.identity?.username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        var result: [SSHCredentials] = []
        var retrievalFailure: (any Error)?
        if let key = node.key {
            if key.requiresPassphraseEntry, node.submission?.passphrase?.isEmpty != false {
                throw TermindSSHError.keyPassphraseRequired
            }
            let stored: SSHResolvedKeyCredential?
            do {
                stored = try secrets.sshKeyCredential(for: key.credentialRef, storage: key.storage)
                if stored != nil, let identity = connectionIdentity(for: node) {
                    accessedIdentityIDs.insert(identity.id)
                }
            } catch {
                stored = nil
                retrievalFailure = error
            }
            if let stored {
                result.append(
                    stored.sshCredential(
                        publicKey: key.publicKey, certificate: key.certificate,
                        passphraseOverride: node.submission?.passphrase,
                        requiresPassphrase: key.requiresPassphraseEntry,
                        requiresUserPresence: key.requiresUserPresence
                    ))
            }
        }
        try Task.checkCancellation()
        if let password = node.submission?.password {
            result.append(.password(password))
        } else if node.submission == nil || node.submission?.identityID != nil,
            let identity = node.identity, identity.usesPassword
        {
            do {
                if let password = try secrets.sshSecret(
                    for: identity.credentialRef, storage: identity.passwordStorage
                ) {
                    result.append(.password(password))
                    accessedIdentityIDs.insert(identity.id)
                }
            } catch {
                if retrievalFailure == nil { retrievalFailure = error }
            }
        }
        if result.isEmpty, let retrievalFailure { throw retrievalFailure }
        let usesIdentity = node.submission == nil || node.submission?.identityID != nil
        if result.isEmpty, node.key != nil || (usesIdentity && node.identity?.hasSecret == true) {
            throw TermindSSHError.missingCredential
        }
        return (username, result)
    }

    private func proxy(
        _ node: Node, accessedIdentityIDs: inout Set<Identity.ID>
    ) throws -> SSHTransportProxy? {
        guard let proxy = node.host.proxy else { return nil }
        guard proxy.isValid else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        var password: SSHSecret?
        if proxy.identityID != nil {
            guard let identity = node.proxyIdentity, identity.usesPassword else {
                throw TermindSSHError.proxy(String(localized: "The proxy password identity is unavailable."))
            }
            password = try secrets.sshSecret(for: identity.credentialRef, storage: identity.passwordStorage)
            guard password != nil else {
                throw TermindSSHError.proxy(String(localized: "The proxy password is unavailable."))
            }
            accessedIdentityIDs.insert(identity.id)
        }
        return SSHTransportProxy(
            kind: proxy.kind, hostname: proxy.hostname, port: proxy.port,
            username: proxy.username, password: password,
            identityID: proxy.identityID
        )
    }

    private func isUntrusted(_ error: TermindSSHError?) -> Bool {
        if case .untrustedHost = error { return true }
        return false
    }
    private func connectionIdentity(for node: Node) -> Identity? {
        if node.submission != nil, node.submission?.identityID == nil { return nil }
        return node.identity
    }

    public init(
        nodes: [Node], secrets: any SecretStoring,
        credentialAccessHandler: SSHCredentialAccessHandler? = nil
    ) {
        self.nodes = nodes
        self.secrets = secrets
        self.credentialAccessHandler = credentialAccessHandler
    }

}
