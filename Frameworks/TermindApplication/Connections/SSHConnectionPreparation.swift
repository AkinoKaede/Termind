import Foundation
import TermindDomain

import struct TermindDomain.Host

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
        public var proxySubmission: SSHProxyAuthenticationSubmission?
        public init(
            host: Host, identity: Identity?, key: SSHKeyRef?, submission: SSHAuthenticationSubmission?,
            trustedKeys: Set<SSHHostKeyIdentity>, proxyIdentity: Identity?,
            proxySubmission: SSHProxyAuthenticationSubmission? = nil
        ) {
            self.host = host
            self.identity = identity
            self.key = key
            self.submission = submission
            self.trustedKeys = trustedKeys
            self.proxyIdentity = proxyIdentity
            self.proxySubmission = proxySubmission
        }

    }
    public var nodes: [Node]
    public var secrets: any SSHRuntimeSecretResolving

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
            do { try Task.checkCancellation() } catch {
                result.clearSecrets()
                throw error
            }
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveSynchronously(
        discoveryOnly: Bool, trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHConnectionConfiguration {
        guard let target = nodes.last else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        var jumps: [SSHRouteHopConfiguration] = []
        var completed = false
        var resolvedCredentials: [SSHCredentials] = []
        var resolvedProxies: [SSHSecret] = []
        defer {
            if !completed {
                for credential in resolvedCredentials { credential.clearSecrets() }
                for secret in resolvedProxies { secret.clear() }
            }
        }
        for (offset, node) in nodes.dropLast().enumerated() {
            do {
                try Task.checkCancellation()
                let material = try credentials(node)
                resolvedCredentials += material.1
                let resolvedProxy = try proxy(node)
                if let password = resolvedProxy?.password { resolvedProxies.append(password) }
                if trustPolicy == .requireKnownHost, node.trustedKeys.isEmpty {
                    throw TermindSSHError.untrustedHost
                }
                jumps.append(
                    SSHRouteHopConfiguration(
                        id: node.host.id, name: node.host.name, host: node.host.host, port: node.host.port,
                        username: material.0, credentials: material.1,
                        expectedHostKeys: node.trustedKeys,
                        proxy: resolvedProxy,
                        authenticationReference: authenticationReference(for: node)
                    ))
            } catch {
                if error is CancellationError { throw error }
                let ssh = error as? TermindSSHError
                if ssh?.isProxyAuthentication == true { throw error }
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
            : try credentials(target)
        resolvedCredentials += material.1
        let resolvedProxy = try proxy(target)
        if let password = resolvedProxy?.password { resolvedProxies.append(password) }
        if !discoveryOnly, trustPolicy == .requireKnownHost, target.trustedKeys.isEmpty {
            throw TermindSSHError.untrustedHost
        }
        completed = true
        return SSHConnectionConfiguration(
            hostID: target.host.id, host: target.host.host, port: target.host.port,
            username: material.0, credentials: material.1, expectedHostKeys: target.trustedKeys,
            proxy: resolvedProxy, jumps: jumps,
            charset: target.host.charset,
            authenticationReference: authenticationReference(for: target)
        )
    }

    private func authenticationReference(for node: Node) -> SSHAuthenticationReference {
        if let identity = connectionIdentity(for: node) {
            return SSHAuthenticationReference(
                identityID: identity.id,
                username: identity.username,
                permitsNone: !identity.hasSecret,
                hasEphemeralSecret: node.submission?.hasPassword == true
                    || node.submission?.hasPassphrase == true
            )
        }
        return SSHAuthenticationReference(
            fallbackKeyID: node.submission?.keyID ?? node.key?.id,
            username: node.submission?.username ?? "",
            permitsNone: node.key == nil && node.submission?.hasPassword != true,
            hasEphemeralSecret: node.submission?.hasPassword == true
                || node.submission?.hasPassphrase == true
        )
    }

    private func credentials(_ node: Node) throws -> (String, [SSHCredentials]) {
        let username = (node.submission?.username ?? node.identity?.username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        var result: [SSHCredentials] = []
        var completed = false
        defer { if !completed { for credential in result { credential.clearSecrets() } } }
        var retrievalFailure: (any Error)?
        if let key = node.key {
            let stored: SSHResolvedKeyCredential?
            do {
                stored = try secrets.sshKeyCredential(for: key)
            } catch {
                stored = nil
                retrievalFailure = error
            }
            if let stored {
                if key.hasPassphrase, !stored.hasSavedPassphrase, node.submission?.hasPassphrase != true {
                    stored.clearSecrets()
                    throw TermindSSHError.keyPassphraseRequired
                }
                result.append(
                    stored.sshCredential(
                        publicKey: key.publicKey, certificate: key.certificate,
                        passphraseOverride: node.submission?.passphraseForConnection(),
                        requiresPassphrase: key.requiresPassphraseEntry,
                        requiresUserPresence: key.requiresUserPresence, keyName: key.label
                    ))
            }
        }
        try Task.checkCancellation()
        if let password = node.submission?.passwordForConnection() {
            result.append(.password(password))
        } else if node.submission == nil || node.submission?.identityID != nil,
            let identity = node.identity, identity.usesPassword
        {
            do {
                if let password = try secrets.sshSecret(
                    for: identity.credentialRef, storage: identity.passwordStorage
                ) {
                    result.append(.password(password))
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
        completed = true
        return (username, result)
    }

    private func proxy(_ node: Node) throws -> SSHTransportProxy? {
        guard let proxy = node.host.proxy else { return nil }
        guard proxy.isValid else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        var password = node.proxySubmission?.passwordForConnection()
        let identity =
            node.proxySubmission?.identityID.flatMap { id in
                node.proxyIdentity?.id == id ? node.proxyIdentity : nil
            } ?? (node.proxySubmission == nil ? node.proxyIdentity : nil)
        if password == nil, proxy.identityID != nil || node.proxySubmission?.identityID != nil {
            guard let identity, identity.usesPassword else {
                throw TermindSSHError.proxyAuthentication(
                    hostID: node.host.id, serverChallenge: false,
                    message: String(localized: "The proxy password identity is unavailable."))
            }
            do {
                password = try secrets.sshSecret(for: identity.credentialRef, storage: identity.passwordStorage)
            } catch {
                throw TermindSSHError.proxyAuthentication(
                    hostID: node.host.id, serverChallenge: false, message: error.localizedDescription)
            }
            guard password != nil else {
                throw TermindSSHError.proxyAuthentication(
                    hostID: node.host.id, serverChallenge: false,
                    message: String(localized: "The proxy password is unavailable."))
            }
        }
        return SSHTransportProxy(
            kind: proxy.kind, hostname: proxy.hostname, port: proxy.port,
            username: node.proxySubmission?.username ?? proxy.username, password: password,
            identityID: node.proxySubmission?.identityID ?? proxy.identityID,
            ownerHostID: node.host.id
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

    public init(nodes: [Node], secrets: any SSHRuntimeSecretResolving) {
        self.nodes = nodes
        self.secrets = secrets
    }

}
