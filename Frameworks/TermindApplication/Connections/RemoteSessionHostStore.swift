import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The host, trust, and credential capabilities required to establish a live
/// SSH-backed session. Session features depend on this port instead of gaining
/// the complete Vault mutation surface from `HostLibraryModel`.
@MainActor
public protocol RemoteSessionHostStore: AnyObject, Sendable {
    func connectionWakeAction(for hostIDs: [UUID]) -> ConnectionWakeAction?
    func host(_ id: Host.ID) -> Host?
    func networkConfigurationStamp(for host: Host) -> Data
    func tailscaleNetwork(for host: Host) throws -> (any SSHNetworkDialing)?
    func savedTailscaleUsername(for host: Host) -> String?
    func tailscaleUsername(for host: Host) -> String
    @discardableResult func saveTailscaleUsername(_ username: String, hostID: Host.ID) -> Bool
    func snippet(_ id: Snippet.ID) -> Snippet?
    func identity(_ id: Identity.ID) -> Identity?
    func identity(for host: Host) -> Identity?
    func identity(for host: Host, protocol connectionProtocol: HostTerminalProtocol) -> Identity?
    func customIdentity(for hostID: Host.ID, purpose: HostCustomIdentityPurpose) -> Identity?
    var customPasswordStorage: PasswordStorage { get }
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
    func telnetConnectionConfiguration(for host: Host) throws -> TelnetConnectionConfiguration
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
    func sshJumpConfigurations(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration]
    func saveConnectionRoute(
        _ route: SSHConnectionRoute, authentication: SSHAuthenticationSubmission?,
        authenticationHostID: Host.ID?, suppliedPassword: String?
    ) throws -> SSHConnectionRoute
    func transportProxy(
        for host: Host, submission: SSHProxyAuthenticationSubmission?
    ) throws -> SSHTransportProxy?
    func sshCredentials(for identity: Identity) -> SSHCredentialResolution
    func passwordSecret(for identity: Identity) throws -> SSHSecret?
    func passwordAvailability(for identity: Identity) -> SecretAvailability
    func saveKeyPassphrase(_ passphrase: String, for keyID: SSHKeyRef.ID) throws
    func keySecretCredential(for key: SSHKeyRef) throws -> SSHResolvedKeyCredential?
    func setConnectionStatus(_ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID)
    func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?, for hostID: Host.ID)
    func trust(_ entry: KnownHostEntry)
    func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws
    func upsert(_ host: Host)
}

extension RemoteSessionHostStore {
    public func connectionWakeAction(for hostIDs: [UUID]) -> ConnectionWakeAction? { nil }
    public func savedTailscaleUsername(for host: Host) -> String? { nil }
    public func tailscaleUsername(for host: Host) -> String { "root" }
    public func saveTailscaleUsername(_ username: String, hostID: Host.ID) -> Bool { false }
    public func networkConfigurationStamp(for host: Host) -> Data { Data() }
    public func tailscaleNetwork(for host: Host) throws -> (any SSHNetworkDialing)? {
        guard !host.isTailscaleManaged else { throw TailscaleConfigurationError.unavailable }
        return nil
    }

    public func saveKeyPassphrase(_ passphrase: String, for keyID: SSHKeyRef.ID) throws {
        throw TermindSSHError.missingCredential
    }

    public func passphraseSubmission(
        for prompt: SSHAuthenticationPrompt, existing: SSHAuthenticationSubmission?,
        passphrase: String?, save: Bool
    ) throws -> SSHAuthenticationSubmission {
        guard let passphrase, !passphrase.isEmpty else { throw TermindSSHError.keyPassphraseRequired }
        var submission =
            existing
            ?? SSHAuthenticationSubmission(
                username: prompt.username, keyID: prompt.selectedKeyID, identityID: prompt.selectedIdentityID)
        guard let keyID = submission.keyID else { throw TermindSSHError.missingCredential }
        if save && prompt.allowsSaving { try saveKeyPassphrase(passphrase, for: keyID) }
        submission.passphrase = passphrase
        return submission
    }

    /// Query the local Keychain rather than relying on synchronized metadata.
    /// Every probe releases its private key and passphrase immediately.
    public func requiresPassphraseEntry(for key: SSHKeyRef) -> Bool {
        guard key.hasPassphrase else { return false }
        do {
            guard let credential = try keySecretCredential(for: key) else { return true }
            defer { credential.clearSecrets() }
            return !credential.hasSavedPassphrase
        } catch { return true }
    }

    public func snippet(_ id: Snippet.ID) -> Snippet? { nil }
    public func customIdentity(for hostID: Host.ID, purpose: HostCustomIdentityPurpose) -> Identity? { nil }
    public var customPasswordStorage: PasswordStorage { .iCloud }
    public func identity(for host: Host, protocol connectionProtocol: HostTerminalProtocol) -> Identity? {
        host.identityID(for: connectionProtocol).flatMap(identity)
    }

    public func telnetConnectionConfiguration(for host: Host) throws -> TelnetConnectionConfiguration {
        guard host.telnetEnabled else { throw HostProtocolUnavailableError(useCase: .telnetTerminal) }
        let identity = identity(for: host, protocol: .telnet)
        let username = identity?.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password: SSHSecret?
        if let identity, identity.usesPassword {
            password = try connectionPasswordSecret(for: identity)
            guard password != nil else { throw TermindSSHError.missingCredential }
        } else {
            password = nil
        }
        return TelnetConnectionConfiguration(
            hostID: host.id, host: host.host, port: host.telnetPort,
            username: username?.isEmpty == false ? username : nil,
            password: password, charset: host.telnetCharset)
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
        if host.isTailscaleManaged {
            guard saveTailscaleUsername(submission.username, hostID: host.id) else {
                throw TailscaleConfigurationError.unavailable
            }
            return host
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
                try upsert(
                    selectedIdentity,
                    passwordUpdate: suppliedPassword.isEmpty ? .remove : .replace(suppliedPassword))
            }
            identity = selectedIdentity
        } else {
            let candidate = customIdentity(for: host.id, purpose: .ssh)
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
                passwordStorage: existing?.passwordStorage ?? customPasswordStorage,
                keyID: submission.keyID, notes: existing?.notes ?? "",
                colorTag: existing?.colorTag ?? .none,
                ownerHostID: host.id, customPurpose: .ssh
            )
            try upsert(
                identity,
                passwordUpdate: suppliedPassword.map {
                    $0.isEmpty ? IdentityPasswordUpdate.remove : .replace($0)
                }
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
                try upsert(
                    selectedIdentity,
                    passwordUpdate: suppliedPassword.isEmpty ? .remove : .replace(suppliedPassword))
            }
            identity = selectedIdentity
        } else {
            let existing = customIdentity(for: host.id, purpose: .proxy)
            identity = Identity(
                id: existing?.id ?? UUID(), name: existing?.name ?? submission.username,
                username: submission.username, credentialRef: existing?.credentialRef ?? "",
                passwordStorage: existing?.passwordStorage ?? customPasswordStorage,
                notes: existing?.notes ?? "",
                colorTag: existing?.colorTag ?? .none, ownerHostID: host.id, customPurpose: .proxy
            )
            try upsert(
                identity,
                passwordUpdate: suppliedPassword.map {
                    $0.isEmpty ? IdentityPasswordUpdate.remove : .replace($0)
                } ?? .remove)
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
            expectedHostKeys: configuration.tailscaleNodeID == nil
                ? keys(id: configuration.hostID, hostname: configuration.host, port: configuration.port) : [],
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
        var result = SSHAdditionalConnectionSnapshot(target: target, jumps: jumps)
        result.tailscaleNodeID = configuration.tailscaleNodeID
        result.requiresTailscale = configuration.network != nil
        return result
    }

    /// Resolves current Identity/Key contents immediately before a silent open.
    /// The returned request is one-shot and must not be retained as session state.
    public func additionalConnectionRequest(
        from snapshot: SSHAdditionalConnectionSnapshot
    ) throws -> SSHConnectionRequest {
        var completed = false
        var resolvedCredentials: [SSHCredentials] = []
        var resolvedProxies: [SSHSecret] = []
        defer {
            if !completed {
                for credential in resolvedCredentials { credential.clearSecrets() }
                for secret in resolvedProxies { secret.clear() }
            }
        }
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
            resolvedProxies.append(password)
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
                    if key.requiresUserPresence || requiresPassphraseEntry(for: key) {
                        credentials.append(.interactionRequired)
                    } else {
                        do {
                            if let stored = try connectionKeySecretCredential(for: key) {
                                credentials.append(
                                    stored.sshCredential(
                                        for: key
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
            resolvedCredentials += credentials
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
        var configuration = SSHConnectionConfiguration(
            hostID: snapshot.target.id, host: snapshot.target.host,
            port: snapshot.target.port, username: targetAuthentication.username,
            credentials: targetAuthentication.credentials,
            expectedHostKeys: snapshot.target.expectedHostKeys,
            proxy: try proxy(snapshot.target.proxy, ownerHostID: snapshot.target.id), jumps: jumps,
            charset: snapshot.target.charset,
            authenticationReference: snapshot.target.authentication
        )
        configuration.beforeConnect = connectionWakeAction(for: snapshot.jumps.map(\.id) + [snapshot.target.id])
        configuration.tailscaleNodeID = snapshot.tailscaleNodeID
        if let first = host(snapshot.jumps.first?.id ?? snapshot.target.id) {
            configuration.network = try tailscaleNetwork(for: first)
        }
        if snapshot.requiresTailscale && configuration.network == nil {
            throw TailscaleConfigurationError.unavailable
        }
        completed = true
        return SSHConnectionRequest(
            configuration: configuration, interactionPolicy: .forbidden
        ).enforcingInteractionPolicy()
    }

    public func connectionPasswordSecret(for identity: Identity) throws -> SSHSecret? {
        try passwordSecret(for: identity)
    }

    public func connectionKeySecretCredential(for key: SSHKeyRef) throws -> SSHResolvedKeyCredential? {
        try keySecretCredential(for: key)
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
