import Foundation
import TermindDomain

import struct TermindDomain.Host

extension RemoteSessionHostStore {
    /// A restored Mosh session has no SSH route in its protocol checkpoint. Rebuild only
    /// metadata when the user explicitly requests a tmux control operation.
    public func resumableControlSnapshot(for host: Host, username: String) throws -> SSHAdditionalConnectionSnapshot {
        let preparation = try prepareSSHConnection(for: host, submissions: [:], proxySubmissions: [:])
        let nodes = preparation.nodes.map { node in
            SSHAdditionalConnectionSnapshot.Node(
                id: node.host.id, name: node.host.name, host: node.host.host, port: node.host.sshPort,
                authentication: .init(
                    identityID: node.identity?.id, fallbackKeyID: node.key?.id,
                    username: node.identity?.username ?? node.tailscaleUsername
                        ?? (node.host.id == host.id ? username : ""),
                    permitsNone: node.host.isTailscaleManaged || node.identity?.hasSecret == false,
                    hasEphemeralSecret: node.identity == nil && !node.host.isTailscaleManaged),
                expectedHostKeys: node.trustedKeys,
                proxy: node.host.proxy.map {
                    .init(
                        kind: $0.kind, hostname: $0.hostname, port: $0.port, username: $0.username,
                        identityID: $0.identityID)
                }, charset: node.host.charset)
        }
        guard let target = nodes.last else { throw SSHConnectionRoute.invalidRouteError }
        var snapshot = SSHAdditionalConnectionSnapshot(target: target, jumps: Array(nodes.dropLast()))
        snapshot.accessHostIDs = preparation.accessHostIDs
        snapshot.tailscaleNodeID = host.tailscale?.stableNodeID
        snapshot.requiresTailscale = preparation.nodes.contains { $0.network != nil }
        return snapshot
    }

    /// Reauthenticates the TCP route. Only explicit control operations authenticate the target as well.
    /// Secrets live for this one opening; normal transport recovery never needs target credentials.
    public func resumableRouteRequest(
        from snapshot: SSHAdditionalConnectionSnapshot,
        authorizeHostKey: SSHHostKeyAuthorizer?,
        keyboardInteractive: SSHKeyboardInteractiveHandler?,
        securityKeySigning: SecurityKeySigningHandler?,
        hostKeyConstraints: [Host.ID: SSHHostKeyConstraint],
        authenticatingTarget: Bool = false
    ) async throws -> SSHConnectionRequest {
        let accessIDs = snapshot.accessHostIDs + snapshot.jumps.map(\.id) + [snapshot.target.id]
        for id in accessIDs {
            if let saved = host(id) { try await resolveHostAccess(saved) }
        }
        try connectionAccessCheck(for: accessIDs)?()
        let connectionID = UUID()
        var resolvedCredentials: [SSHCredentials] = []
        var resolvedProxies: [SSHSecret] = []
        var completed = false
        defer {
            if !completed {
                for credential in resolvedCredentials { credential.clearSecrets() }
                for secret in resolvedProxies { secret.clear() }
            }
        }

        func prompt(
            node: SSHAdditionalConnectionSnapshot.Node, label: String, username: String,
            proxy: SSHAdditionalConnectionSnapshot.Proxy? = nil
        ) async throws -> SSHSecret {
            guard let keyboardInteractive else { throw SSHInteractionRequired() }
            let answers = try await keyboardInteractive(
                SSHKeyboardInteractiveChallenge(
                    connectionID: connectionID, hostID: node.id,
                    hostname: proxy?.hostname ?? node.host, port: proxy?.port ?? node.port,
                    username: username, round: 0, name: node.name, instruction: "",
                    prompts: [.init(text: label, echo: false)]))
            try Task.checkCancellation()
            guard answers.count == 1 else { throw CancellationError() }
            return SSHSecret(answers[0])
        }

        func proxy(for node: SSHAdditionalConnectionSnapshot.Node) async throws -> SSHTransportProxy? {
            guard let value = node.proxy else { return nil }
            let identity = value.identityID.flatMap(self.identity)
            if value.identityID != nil, identity == nil { throw TermindSSHError.missingCredential }
            var password: SSHSecret?
            if let identity { password = try connectionPasswordSecret(for: identity) }
            if password == nil, identity != nil || !value.username.isEmpty {
                password = try await prompt(
                    node: node, label: String(localized: "Password"), username: value.username, proxy: value)
            }
            if let password { resolvedProxies.append(password) }
            return SSHTransportProxy(
                kind: value.kind, hostname: value.hostname, port: value.port,
                username: value.username, password: password, identityID: value.identityID, ownerHostID: node.id)
        }

        var jumps: [SSHRouteHopConfiguration] = []
        for node in snapshot.jumps + (authenticatingTarget ? [snapshot.target] : []) {
            try Task.checkCancellation()
            let reference = node.authentication
            let identity = reference.identityID.flatMap(self.identity)
            if reference.identityID != nil, identity == nil { throw TermindSSHError.missingCredential }
            var username = (identity?.username ?? reference.username).trimmingCharacters(in: .whitespacesAndNewlines)
            if username.isEmpty, authenticatingTarget, let keyboardInteractive {
                let answers = try await keyboardInteractive(
                    SSHKeyboardInteractiveChallenge(
                        connectionID: connectionID, hostID: node.id, hostname: node.host, port: node.port,
                        username: "", round: 0, name: node.name, instruction: "",
                        prompts: [.init(text: String(localized: "Username"), echo: true)]))
                try Task.checkCancellation()
                guard answers.count == 1 else { throw CancellationError() }
                username = answers[0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !username.isEmpty else { throw TermindSSHError.missingUsername }
            var credentials: [SSHCredentials] = []
            if let keyID = identity?.keyID ?? reference.fallbackKeyID {
                guard let key = key(keyID), let stored = try connectionKeySecretCredential(for: key) else {
                    throw TermindSSHError.missingCredential
                }
                do {
                    let passphrase =
                        if key.hasPassphrase && !stored.hasSavedPassphrase {
                            try await prompt(node: node, label: String(localized: "Passphrase"), username: username)
                        } else {
                            nil as SSHSecret?
                        }
                    let credential = stored.sshCredential(for: key, passphraseOverride: passphrase)
                    credentials.append(credential)
                    resolvedCredentials.append(credential)
                } catch {
                    stored.clearSecrets()
                    throw error
                }
            }
            if let identity, identity.usesPassword, let password = try connectionPasswordSecret(for: identity) {
                let credential = SSHCredentials.password(password)
                credentials.append(credential)
                resolvedCredentials.append(credential)
            }
            if credentials.isEmpty,
                reference.hasEphemeralSecret || !reference.permitsNone || identity?.usesPassword == true
            {
                let credential = SSHCredentials.password(
                    try await prompt(node: node, label: String(localized: "Password"), username: username))
                credentials.append(credential)
                resolvedCredentials.append(credential)
            }
            let known = Set(
                knownHosts(for: Host(id: node.id, name: node.name, host: node.host, port: node.port)).map(\.identity))
            jumps.append(
                SSHRouteHopConfiguration(
                    id: node.id, name: node.name, host: node.host, port: node.port,
                    username: username, credentials: credentials,
                    expectedHostKeys: known.isEmpty ? node.expectedHostKeys : known,
                    proxy: try await proxy(for: node), authenticationReference: reference))
        }
        let target = authenticatingTarget ? jumps.removeLast() : nil
        let targetProxy: SSHTransportProxy?
        if let target {
            targetProxy = target.proxy
        } else {
            targetProxy = try await proxy(for: snapshot.target)
        }
        var configuration = SSHConnectionConfiguration(
            hostID: snapshot.target.id, host: snapshot.target.host, port: snapshot.target.port,
            username: target?.username ?? snapshot.target.authentication.username,
            credentials: target?.credentials ?? [], expectedHostKeys: target?.expectedHostKeys ?? [],
            proxy: targetProxy, jumps: jumps, charset: snapshot.target.charset,
            authenticationReference: snapshot.target.authentication)
        configuration.accessHostIDs = accessIDs
        configuration.accessCheck = connectionAccessCheck(for: accessIDs)
        configuration.beforeConnect = connectionWakeAction(for: accessIDs)
        configuration.tailscaleNodeID = snapshot.tailscaleNodeID
        if let first = host(snapshot.jumps.first?.id ?? snapshot.target.id) {
            configuration.network = try tailscaleNetwork(for: first)
        }
        if snapshot.requiresTailscale, configuration.network == nil { throw TailscaleConfigurationError.unavailable }
        try Task.checkCancellation()
        completed = true
        return SSHConnectionRequest(
            configuration: configuration, authorizeHostKey: authorizeHostKey,
            keyboardInteractive: keyboardInteractive, securityKeySigning: securityKeySigning,
            hostKeyConstraints: hostKeyConstraints)
    }
}
