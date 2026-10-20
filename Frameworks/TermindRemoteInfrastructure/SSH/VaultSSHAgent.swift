// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

/// One capability per physical connection. Deliberately does not cache private
/// keys or passphrases across requests, callers, or connections.
@MainActor
public final class VaultSSHAgent: SSHAgentForwarding {
    private let library: HostLibraryModel
    private let hostID: UUID
    private let revision: UInt64
    private let connectionID = UUID()
    private let hostname: String
    private let port: Int
    private let username: String
    private let interactionPolicy: SSHInteractionPolicy
    private let unlock: SSHKeyboardInteractiveHandler?
    private let securityKeySigning: SecurityKeySigningHandler?
    private let canInteract: @MainActor @Sendable () -> Bool
    private var closed = false

    public static func factory(
        library: HostLibraryModel,
        unlock: SSHKeyboardInteractiveHandler? = nil,
        securityKeySigning: SecurityKeySigningHandler? = nil,
        canInteract: @escaping @MainActor @Sendable () -> Bool = { true },
        interactionContext: (@MainActor @Sendable (SSHConnectionRequest) -> SSHAgentInteractionContext)? = nil
    ) -> SSHAgentForwardingFactory {
        { request in
            await MainActor.run {
                guard request.permitsAgentForwarding,
                    library.host(request.configuration.hostID)?.agentForwardingEnabled == true
                else { return nil }
                let context = interactionContext?(request)
                return VaultSSHAgent(
                    library: library, request: request,
                    unlock: context?.unlock ?? unlock,
                    securityKeySigning: context?.securityKeySigning ?? securityKeySigning,
                    canInteract: context?.canInteract ?? canInteract)
            }
        }
    }

    private init(
        library: HostLibraryModel, request: SSHConnectionRequest,
        unlock: SSHKeyboardInteractiveHandler?, securityKeySigning: SecurityKeySigningHandler?,
        canInteract: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.library = library
        hostID = request.configuration.hostID
        revision = library.agentForwardingRevision(for: hostID)
        hostname = request.configuration.host
        port = request.configuration.port
        username = request.configuration.username
        interactionPolicy = request.interactionPolicy
        self.unlock = unlock ?? request.keyboardInteractive
        self.securityKeySigning = securityKeySigning ?? request.securityKeySigning
        self.canInteract = canInteract
    }

    private func check() throws {
        try Task.checkCancellation()
        guard !closed, library.host(hostID)?.agentForwardingEnabled == true,
            library.agentForwardingRevision(for: hostID) == revision
        else { throw SSHAgentProtocol.Failure.unavailable }
    }

    public func identities() async throws -> [SSHAgentIdentity] {
        try check()
        var result: [SSHAgentIdentity] = []
        var seen = Set<Data>()
        for key in library.keys {
            guard library.keyAvailability(for: key) == .available,
                let blob = Self.blob(key.publicKey)
            else { continue }
            if let certificate = Self.blob(key.certificate), seen.insert(certificate).inserted {
                result.append(SSHAgentIdentity(blob: certificate, comment: key.label))
            }
            if seen.insert(blob).inserted { result.append(SSHAgentIdentity(blob: blob, comment: key.label)) }
        }
        return result
    }

    public func sign(key blob: Data, data: Data, flags: UInt32) async throws -> Data {
        try check()
        guard
            let key = library.keys.first(where: {
                (Self.blob($0.publicKey) == blob || Self.blob($0.certificate) == blob)
                    && library.keyAvailability(for: $0) == .available
            })
        else { throw SSHAgentProtocol.Failure.unavailable }
        let keyRevision = library.agentForwardingKeyRevision
        if key.algorithm == .securityKey {
            guard flags == 0, Self.blob(key.publicKey) == blob, let credential = key.securityKey else {
                throw SSHAgentProtocol.Failure.invalid
            }
            guard interactionPolicy == .allowed, canInteract(), let securityKeySigning else {
                throw SSHInteractionRequired()
            }
            let request = SecurityKeySigningRequest(
                hostID: hostID, hostname: hostname, credential: credential, challenge: data, keyName: key.label)
            let assertion = try await securityKeySigning(request)
            try check()
            guard library.agentForwardingKeyRevision == keyRevision, library.keys.contains(key), canInteract() else {
                throw SSHAgentProtocol.Failure.unavailable
            }
            return try WebAuthnSSH.signature(assertion, for: request)
        }
        let secrets = library.agentForwardingSecrets
        let resolution = Task.detached { try secrets.sshKeyCredential(for: key.credentialRef, storage: key.storage) }
        guard let credential = try await resolution.value else { throw SSHAgentProtocol.Failure.unavailable }
        defer { credential.clearSecrets() }
        let needsPassphrase = key.hasPassphrase && !credential.hasSavedPassphrase
        let needsInteraction = needsPassphrase || key.requiresUserPresence
        if needsInteraction {
            guard interactionPolicy == .allowed, canInteract() else { throw SSHInteractionRequired() }
        }
        var passphrase: SSHSecret?
        defer { passphrase?.clear() }
        if needsPassphrase {
            guard let unlock else { throw SSHInteractionRequired() }
            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: connectionID, hostID: hostID, hostname: hostname, port: port,
                username: username, round: 0, name: String(localized: "Agent Forwarding"),
                instruction: key.label + "\n" + key.fingerprint,
                prompts: [.init(text: String(localized: "Passphrase"), echo: false)])
            var answers = try await unlock(challenge)
            defer { answers.removeAll() }
            guard answers.count == 1 else { throw CancellationError() }
            passphrase = SSHSecret(answers[0])
        }
        try check()
        guard library.agentForwardingKeyRevision == keyRevision, library.keys.contains(key),
            !needsInteraction || canInteract()
        else { throw SSHInteractionRequired() }
        let password = passphrase
        let allowInteraction = interactionPolicy == .allowed && canInteract()
        let task = Task.detached {
            try Task.checkCancellation()
            return try SSHAgentKeySigner.sign(
                credential: credential, passphrase: password, algorithm: key.algorithm, data: data, flags: flags,
                allowInteraction: allowInteraction)
        }
        let signature = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try check()
        guard library.agentForwardingKeyRevision == keyRevision, library.keys.contains(key),
            !needsInteraction || canInteract()
        else {
            throw SSHAgentProtocol.Failure.unavailable
        }
        return signature
    }
    public func close() { closed = true }
    private static func blob(_ line: String) -> Data? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }
}
