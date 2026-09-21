import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The host, trust, and credential capabilities required to establish a live
/// SSH-backed session. Session features depend on this port instead of gaining
/// the complete Vault mutation surface from `HostLibraryModel`.
@MainActor
public protocol RemoteSessionHostStore: AnyObject, Sendable {
    func host(_ id: Host.ID) -> Host?
    func identity(_ id: Identity.ID) -> Identity?
    func identity(for host: Host) -> Identity?
    func key(_ id: SSHKeyRef.ID) -> SSHKeyRef?
    func knownHosts(for host: Host) -> [KnownHostEntry]
    func route(for host: Host) -> [Host]
    func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> Set<SSHHostKeyIdentity>
    func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation
    func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHConnectionConfiguration
    func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration]
    func prepareSSHConnection(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation
    func sshJumpConfigurations(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration]
    func saveConnectionRoute(
        _ route: SSHConnectionRoute, authentication: SSHAuthenticationSubmission?,
        authenticationHostID: Host.ID?, suppliedPassword: String?
    ) throws -> SSHConnectionRoute
    func transportProxy(for host: Host) throws -> SSHTransportProxy?
    func transportProxy(
        for host: Host, submission: SSHProxyAuthenticationSubmission?
    ) throws -> SSHTransportProxy?
    func sshCredentials(for identity: Identity) -> SSHCredentialResolution
    func passwordSecret(for identity: Identity) throws -> SSHSecret?
    func passwordAvailability(for identity: Identity) -> SecretAvailability
    func keySecretCredential(for key: SSHKeyRef) throws -> SSHResolvedKeyCredential?
    func recordIdentityCredentialAccess(_ identityIDs: Set<Identity.ID>, at date: Date)
    func setConnectionStatus(_ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID)
    func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?, for hostID: Host.ID)
    func trust(_ entry: KnownHostEntry)
    func markKnownHostMismatched(hostname: String, port: Int)
    @discardableResult func upsert(_ identity: Identity) -> Bool
    func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws
    func upsert(_ host: Host)
}

extension RemoteSessionHostStore {
    public func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation {
        try prepareSSHConnection(for: host, submissions: submissions, proxySubmissions: [:])
    }

    public func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHConnectionConfiguration {
        try sshConnectionConfiguration(
            for: host, submissions: submissions, proxySubmissions: [:],
            temporaryHostKeys: temporaryHostKeys, trustPolicy: trustPolicy)
    }

    public func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration] {
        try sshJumpConfigurations(
            for: host, submissions: submissions, proxySubmissions: [:],
            temporaryHostKeys: temporaryHostKeys, trustPolicy: trustPolicy)
    }

    public func prepareSSHConnection(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation {
        try prepareSSHConnection(for: route, submissions: submissions, proxySubmissions: [:])
    }

    public func sshJumpConfigurations(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration] {
        try sshJumpConfigurations(
            for: route, submissions: submissions, proxySubmissions: [:],
            temporaryHostKeys: temporaryHostKeys, trustPolicy: trustPolicy)
    }

    /// Captures a desktop authentication form without saving its input. A
    /// selected Identity stays reference-only so its saved password is read
    /// directly into a one-shot buffer only when the connection is resolved.
    public func authenticationSubmission(
        username: String, password: String?, passphrase: String?, keyID: SSHKeyRef.ID?,
        selectedIdentity: Identity?
    ) throws -> SSHAuthenticationSubmission {
        SSHAuthenticationSubmission(
            username: username,
            password: password,
            passphrase: passphrase, keyID: keyID, identityID: selectedIdentity?.id
        )
    }

    /// Saves the optional form edit before associating its Host. A selected
    /// Identity changes only for an explicitly supplied password. Custom input
    /// reuses the Host's Identity, preserving the existing save boundaries.
    public func saveAuthentication(
        _ submission: SSHAuthenticationSubmission, for host: Host,
        selectedIdentity: Identity?, suppliedPassword: String?
    ) throws -> Host {
        let identity: Identity
        if let selectedIdentity {
            if let suppliedPassword {
                switch passwordAvailability(for: selectedIdentity) {
                case .missing, .failed:
                    throw TermindSSHError.library(
                        String(localized: "The selected Identity cannot be updated on this device."))
                case .notConfigured, .available:
                    break
                }
                try upsert(selectedIdentity, passwordUpdate: .replace(suppliedPassword))
            }
            identity = selectedIdentity
        } else {
            let candidate = self.identity(for: host)
            let existing: Identity?
            if let candidate {
                switch passwordAvailability(for: candidate) {
                case .missing, .failed: existing = nil
                case .notConfigured, .available: existing = candidate
                }
            } else {
                existing = nil
            }
            identity = Identity(
                id: existing?.id ?? UUID(), name: existing?.name ?? submission.username,
                username: submission.username, credentialRef: existing?.credentialRef ?? "",
                passwordStorage: existing?.passwordStorage ?? .iCloud,
                keyID: submission.keyID, notes: existing?.notes ?? "",
                lastUsedAt: existing?.lastUsedAt, colorTag: existing?.colorTag ?? .none
            )
            try upsert(
                identity,
                passwordUpdate: submission.password.map(IdentityPasswordUpdate.replace)
                    ?? (existing == nil ? .remove : .keep)
            )
        }
        var updated = host
        updated.identityID = identity.id
        upsert(updated)
        return updated
    }

    public func saveProxyAuthentication(
        _ submission: SSHProxyAuthenticationSubmission, for host: Host,
        selectedIdentity: Identity?, suppliedPassword: String?
    ) throws -> Host {
        guard var proxy = host.proxy else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        let identity: Identity
        if let selectedIdentity {
            if let suppliedPassword {
                switch passwordAvailability(for: selectedIdentity) {
                case .missing, .failed:
                    throw TermindSSHError.library(
                        String(localized: "The selected Identity cannot be updated on this device."))
                case .notConfigured, .available:
                    break
                }
                try upsert(selectedIdentity, passwordUpdate: .replace(suppliedPassword))
            }
            identity = selectedIdentity
        } else {
            identity = Identity(name: submission.username, username: submission.username)
            try upsert(
                identity,
                passwordUpdate: suppliedPassword.map(IdentityPasswordUpdate.replace) ?? .remove)
        }
        proxy.username = submission.username
        proxy.identityID = identity.id
        var updated = host
        updated.proxy = proxy
        upsert(updated)
        return updated
    }

    /// Captures the authenticated route without retaining password, key, or
    /// passphrase material. Once-only trust is deliberately not promoted into
    /// permission for additional connections.
    public func additionalConnectionSnapshot(
        from configuration: SSHConnectionConfiguration
    ) -> SSHAdditionalConnectionSnapshot {
        func keys(id: UUID, hostname: String, port: Int) -> Set<SSHHostKeyIdentity> {
            Set(knownHosts(for: Host(id: id, name: hostname, host: hostname, port: port)).map(\.identity))
        }

        func proxy(_ value: SSHTransportProxy?) -> SSHAdditionalConnectionSnapshot.Proxy? {
            value.map {
                SSHAdditionalConnectionSnapshot.Proxy(
                    kind: $0.kind, hostname: $0.hostname, port: $0.port,
                    username: $0.username,
                    identityID: $0.identityID
                )
            }
        }

        let target = SSHAdditionalConnectionSnapshot.Node(
            id: configuration.hostID, name: configuration.host,
            host: configuration.host, port: configuration.port,
            authentication: configuration.authenticationReference,
            expectedHostKeys: keys(
                id: configuration.hostID, hostname: configuration.host,
                port: configuration.port
            ),
            proxy: proxy(configuration.proxy)
        )
        let jumps = configuration.jumps.map { hop in
            SSHAdditionalConnectionSnapshot.Node(
                id: hop.id, name: hop.name, host: hop.host, port: hop.port,
                authentication: hop.authenticationReference,
                expectedHostKeys: keys(id: hop.id, hostname: hop.host, port: hop.port),
                proxy: proxy(hop.proxy)
            )
        }
        return SSHAdditionalConnectionSnapshot(target: target, jumps: jumps)
    }

    /// Resolves current Identity/Key contents immediately before a silent open.
    /// The returned request is one-shot and must not be retained as session state.
    public func additionalConnectionRequest(
        from snapshot: SSHAdditionalConnectionSnapshot
    ) throws -> SSHConnectionRequest {
        func proxy(
            _ value: SSHAdditionalConnectionSnapshot.Proxy?, ownerHostID: Host.ID
        ) throws -> SSHTransportProxy? {
            guard let value else { return nil }
            guard let identityID = value.identityID else {
                return SSHTransportProxy(
                    kind: value.kind, hostname: value.hostname, port: value.port,
                    username: value.username, ownerHostID: ownerHostID
                )
            }
            guard let identity = identity(identityID) else {
                throw TermindSSHError.missingCredential
            }
            let password = try connectionPasswordSecret(for: identity)
            guard let password else { throw TermindSSHError.missingCredential }
            return SSHTransportProxy(
                kind: value.kind, hostname: value.hostname, port: value.port,
                username: value.username, password: password,
                identityID: identity.id, ownerHostID: ownerHostID
            )
        }

        func authentication(
            _ node: SSHAdditionalConnectionSnapshot.Node
        ) throws -> (username: String, credentials: [SSHCredentials]) {
            let reference = node.authentication
            let resolvedIdentity = reference.identityID.flatMap(identity)
            if reference.identityID != nil, resolvedIdentity == nil {
                throw TermindSSHError.missingCredential
            }

            let username = (resolvedIdentity?.username ?? reference.username)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw TermindSSHError.missingUsername }

            var credentials: [SSHCredentials] = []
            var failures: [any Error] = []
            let keyID = resolvedIdentity?.keyID ?? reference.fallbackKeyID
            if let keyID {
                if let key = key(keyID) {
                    if key.requiresPassphraseEntry || key.requiresUserPresence {
                        credentials.append(.interactionRequired)
                    } else {
                        do {
                            if let stored = try connectionKeySecretCredential(
                                for: key, identityID: resolvedIdentity?.id
                            ) {
                                credentials.append(
                                    stored.sshCredential(
                                        publicKey: key.publicKey,
                                        certificate: key.certificate,
                                        requiresPassphrase: key.requiresPassphraseEntry,
                                        requiresUserPresence: key.requiresUserPresence
                                    )
                                )
                            } else {
                                failures.append(TermindSSHError.missingCredential)
                            }
                        } catch {
                            failures.append(error)
                        }
                    }
                } else {
                    failures.append(TermindSSHError.missingCredential)
                }
            }

            if let resolvedIdentity, resolvedIdentity.usesPassword {
                do {
                    if let password = try connectionPasswordSecret(for: resolvedIdentity) {
                        credentials.append(.password(password))
                    } else {
                        failures.append(TermindSSHError.missingCredential)
                    }
                } catch {
                    failures.append(error)
                }
            }

            if credentials.isEmpty {
                if reference.hasEphemeralSecret { throw SSHInteractionRequired() }
                if !reference.permitsNone { throw failures.first ?? TermindSSHError.missingCredential }
            }
            return (username, credentials)
        }

        let targetAuthentication = try authentication(snapshot.target)
        let jumps = try snapshot.jumps.map { node in
            let resolved = try authentication(node)
            return SSHRouteHopConfiguration(
                id: node.id, name: node.name, host: node.host, port: node.port,
                username: resolved.username, credentials: resolved.credentials,
                expectedHostKeys: node.expectedHostKeys,
                proxy: try proxy(node.proxy, ownerHostID: node.id),
                authenticationReference: node.authentication
            )
        }
        let configuration = SSHConnectionConfiguration(
            hostID: snapshot.target.id, host: snapshot.target.host,
            port: snapshot.target.port, username: targetAuthentication.username,
            credentials: targetAuthentication.credentials,
            expectedHostKeys: snapshot.target.expectedHostKeys,
            proxy: try proxy(snapshot.target.proxy, ownerHostID: snapshot.target.id), jumps: jumps,
            authenticationReference: snapshot.target.authentication
        )
        return SSHConnectionRequest(
            configuration: configuration, interactionPolicy: .forbidden
        ).enforcingInteractionPolicy()
    }

    public func connectionPasswordSecret(for identity: Identity) throws -> SSHSecret? {
        let password = try passwordSecret(for: identity)
        if password != nil {
            recordIdentityCredentialAccess([identity.id], at: Date())
        }
        return password
    }

    public func connectionKeySecretCredential(
        for key: SSHKeyRef, identityID: Identity.ID?
    ) throws -> SSHResolvedKeyCredential? {
        let credential = try keySecretCredential(for: key)
        if credential != nil, let identityID {
            recordIdentityCredentialAccess([identityID], at: Date())
        }
        return credential
    }

    public func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> Set<SSHHostKeyIdentity> {
        try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys,
            trustPolicy: .requireKnownHost
        )
    }

    public func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionConfiguration {
        try sshConnectionConfiguration(
            for: host, submissions: submissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: .requireKnownHost
        )
    }

    public func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> [SSHRouteHopConfiguration] {
        try sshJumpConfigurations(
            for: host, submissions: submissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: .requireKnownHost
        )
    }

    public func prepareSSHConnection(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionPreparation {
        var preparation = try prepareSSHConnection(for: host, submissions: submissions)
        for index in preparation.nodes.indices {
            if let key = temporaryHostKeys[preparation.nodes[index].host.id] {
                preparation.nodes[index].trustedKeys.insert(key)
            }
        }
        return preparation
    }

    public func prepareSSHConnection(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionPreparation {
        var preparation = try prepareSSHConnection(
            for: host, submissions: submissions, proxySubmissions: proxySubmissions)
        for index in preparation.nodes.indices {
            if let key = temporaryHostKeys[preparation.nodes[index].host.id] {
                preparation.nodes[index].trustedKeys.insert(key)
            }
        }
        return preparation
    }
}
