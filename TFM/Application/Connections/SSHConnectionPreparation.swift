import Foundation
import TermindDomain

import struct TermindDomain.Host

/// A value snapshot taken on MainActor. Resolving Keychain references can block and
/// therefore happens on a detached worker, before any SSH transport is opened.
nonisolated struct SSHConnectionPreparation: Sendable {
    struct Node: Sendable {
        var host: Host
        var identity: Identity?
        var key: SSHKeyRef?
        var submission: SSHAuthenticationSubmission?
        var trustedKeys: Set<SSHHostKeyIdentity>
        var proxyIdentity: Identity?
    }
    var nodes: [Node]
    var secrets: any SecretStoring

    func resolve(discoveryOnly: Bool = false) async throws -> SSHConnectionConfiguration {
        let task = Task.detached { try resolveSynchronously(discoveryOnly: discoveryOnly) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveSynchronously(discoveryOnly: Bool) throws -> SSHConnectionConfiguration {
        guard let target = nodes.last else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        var jumps: [SSHRouteHopConfiguration] = []
        for (offset, node) in nodes.dropLast().enumerated() {
            do {
                try Task.checkCancellation()
                let material = try credentials(node)
                guard !node.trustedKeys.isEmpty else { throw TermindSSHError.untrustedHost }
                jumps.append(
                    SSHRouteHopConfiguration(
                        id: node.host.id, name: node.host.name, host: node.host.host, port: node.host.port,
                        username: material.0, credentials: material.1,
                        expectedHostKeys: node.trustedKeys, proxy: try proxy(node)
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
        let material = discoveryOnly ? ("", [SSHCredentials]()) : try credentials(target)
        if !discoveryOnly, target.trustedKeys.isEmpty { throw TermindSSHError.untrustedHost }
        return SSHConnectionConfiguration(
            hostID: target.host.id, host: target.host.host, port: target.host.port,
            username: material.0, credentials: material.1, expectedHostKeys: target.trustedKeys,
            proxy: try proxy(target), jumps: jumps
        )
    }

    private func credentials(_ node: Node) throws -> (String, [SSHCredentials]) {
        let username = (node.submission?.username ?? node.identity?.username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        var result: [SSHCredentials] = []
        if let key = node.key {
            if key.requiresPassphraseEntry, node.submission?.passphrase?.isEmpty != false {
                throw TermindSSHError.keyPassphraseRequired
            }
            if let credential = try? secrets.keyCredential(for: key.credentialRef, storage: key.storage) {
                result.append(
                    credential.sshCredential(
                        publicKey: key.publicKey, certificate: key.certificate,
                        passphraseOverride: node.submission?.passphrase
                    ))
            }
        }
        try Task.checkCancellation()
        if let password = node.submission?.password {
            result.append(.password(password))
        } else if node.submission == nil || node.submission?.identityID != nil,
            let identity = node.identity, identity.usesPassword,
            let password = try? secrets.string(for: identity.credentialRef, storage: identity.passwordStorage)
        {
            result.append(.password(password))
        }
        guard !result.isEmpty else { throw TermindSSHError.missingCredential }
        return (username, result)
    }

    private func proxy(_ node: Node) throws -> SSHTransportProxy? {
        guard let proxy = node.host.proxy else { return nil }
        guard proxy.isValid else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        var password: String?
        if proxy.identityID != nil {
            guard let identity = node.proxyIdentity, identity.usesPassword else {
                throw TermindSSHError.proxy(String(localized: "The proxy password identity is unavailable."))
            }
            password = try secrets.string(for: identity.credentialRef, storage: identity.passwordStorage)
            guard password != nil else {
                throw TermindSSHError.proxy(String(localized: "The proxy password is unavailable."))
            }
        }
        return SSHTransportProxy(
            kind: proxy.kind, hostname: proxy.hostname, port: proxy.port,
            username: proxy.username, password: password
        )
    }

    private func isUntrusted(_ error: TermindSSHError?) -> Bool {
        if case .untrustedHost = error { return true }
        return false
    }
}
