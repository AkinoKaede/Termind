// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SSHCredentialRecoveryTests {
    @Test(arguments: [false, true])
    func unavailablePasswordOrEncryptedKeyIsNotMissingAndDoesNotPolluteStorageError(_ useKey: Bool) throws {
        let secrets = RecoveryTestSecrets()
        let key = SSHKeyRef(label: "Key", credentialRef: "key", hasPassphrase: true)
        let identity = Identity(
            name: "User", username: "user", credentialRef: useKey ? "" : "password",
            keyID: useKey ? key.id : nil)
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        try secrets.setString("password", for: "password", storage: .thisDevice)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "key", passphrase: "phrase")), for: "key", storage: .thisDevice)
        secrets.unavailable = true
        let library = HostLibraryModel(hosts: [host], keys: [key], identities: [identity], secrets: secrets)

        let result = library.sshCredentials(for: identity)
        #expect(result.accessUnavailable != nil)
        #expect(result.credentials.isEmpty)
        #expect(result.requiredPassphraseKeyID == nil)
        #expect(library.storageError == nil)
        #expect(throws: SSHCredentialAccessUnavailable(hostID: host.id)) {
            try library.sshConnectionConfiguration(
                for: host, submissions: [:], proxySubmissions: [:], temporaryHostKeys: [:], trustPolicy: .allowChallenge
            )
        }

        secrets.unavailable = false
        let recovered = library.sshCredentials(for: identity)
        defer { for credential in recovered.credentials { credential.clearSecrets() } }
        #expect(recovered.credentials.count == 1)
        #expect(recovered.accessUnavailable == nil)
        #expect(library.storageError == nil)
    }

    @Test func keyFailureKeepsUsablePasswordFallback() throws {
        let secrets = RecoveryTestSecrets()
        let key = SSHKeyRef(label: "Key", credentialRef: "key")
        let identity = Identity(name: "User", username: "user", credentialRef: "password", keyID: key.id)
        try secrets.setString("password", for: "password", storage: .thisDevice)
        secrets.unavailableKeysOnly = true
        let library = HostLibraryModel(keys: [key], identities: [identity], secrets: secrets)
        let result = library.sshCredentials(for: identity)
        defer { for credential in result.credentials { credential.clearSecrets() } }
        #expect(result.accessUnavailable != nil)
        #expect(result.credentials.count == 1)
        guard case .password = result.credentials.first else {
            Issue.record("Available password fallback must survive a protected key read failure")
            return
        }
    }

    @Test func unreadablePasswordFallbackWaitsBeforeRequestingAnUnsavedKeyPassphrase() async throws {
        let secrets = RecoveryTestSecrets()
        let key = SSHKeyRef(label: "Encrypted", credentialRef: "key", hasPassphrase: true)
        try secrets.setKeyCredential(.software(.init(privateKey: "key")), for: "key", storage: key.storage)
        secrets.unavailablePasswordsOnly = true
        let identity = Identity(name: "User", username: "user", credentialRef: "password", keyID: key.id)
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], keys: [key], identities: [identity], secrets: secrets)
        #expect(throws: SSHCredentialAccessUnavailable(hostID: host.id)) {
            try library.sshConnectionConfiguration(
                for: host, submissions: [:], proxySubmissions: [:], temporaryHostKeys: [:], trustPolicy: .allowChallenge
            )
        }
        let preparation = try library.prepareSSHConnection(for: host, submissions: [:], proxySubmissions: [:])
        await #expect(throws: SSHCredentialAccessUnavailable(hostID: host.id)) {
            try await preparation.resolve(trustPolicy: .allowChallenge)
        }
    }

    @Test(arguments: [false, true])
    func routeAndProxyKeepUnavailableClassificationAndOwner(_ proxy: Bool) async throws {
        let secrets = RecoveryTestSecrets()
        secrets.unavailable = true
        let identity = Identity(name: "Protected", username: "user", credentialRef: "password")
        let targetIdentity = Identity(name: "Target", username: "target")
        let jump = Host(name: "Jump", host: "jump.invalid", identityID: identity.id)
        let host = Host(
            name: "Server", host: "server.invalid", identityID: targetIdentity.id,
            jumpHostID: proxy ? nil : jump.id,
            proxy: proxy
                ? HostProxy(
                    kind: .http, hostname: "proxy.invalid", port: 8080, username: "proxy", identityID: identity.id)
                : nil)
        let library = HostLibraryModel(hosts: [jump, host], identities: [identity, targetIdentity], secrets: secrets)
        let expected = SSHCredentialAccessUnavailable(hostID: proxy ? host.id : jump.id)
        #expect(throws: expected) {
            try library.sshConnectionConfiguration(
                for: host, submissions: [:], proxySubmissions: [:], temporaryHostKeys: [:], trustPolicy: .allowChallenge
            )
        }
        let preparation = try library.prepareSSHConnection(for: host, submissions: [:], proxySubmissions: [:])
        await #expect(throws: expected) {
            try await preparation.resolve(trustPolicy: .allowChallenge)
        }
        #expect(library.storageError == nil)
    }

    @Test(arguments: [false, true])
    func silentAdditionalConnectionsKeepProtectedKeyErrorsIncludingJumps(_ jump: Bool) throws {
        let secrets = RecoveryTestSecrets()
        secrets.unavailable = true
        let key = SSHKeyRef(label: "Encrypted", credentialRef: "key", hasPassphrase: true)
        let identity = Identity(name: "User", username: "user", keyID: key.id)
        let library = HostLibraryModel(keys: [key], identities: [identity], secrets: secrets)
        let node = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Protected", host: "protected.invalid", port: 22,
            authentication: SSHAuthenticationReference(identityID: identity.id, username: "user"),
            expectedHostKeys: [], proxy: nil)
        let target = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Target", host: "target.invalid", port: 22,
            authentication: SSHAuthenticationReference(username: "user", permitsNone: true),
            expectedHostKeys: [], proxy: nil)
        #expect(throws: SSHCredentialAccessUnavailable(hostID: node.id)) {
            try library.additionalConnectionRequest(
                from: SSHAdditionalConnectionSnapshot(target: jump ? target : node, jumps: jump ? [node] : []))
        }
    }

    @Test func realMissingCredentialStillRequestsAuthentication() {
        let identity = Identity(name: "User", username: "user", credentialRef: "absent")
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        #expect(throws: TermindSSHError.self) {
            try library.sshConnectionConfiguration(
                for: host, submissions: [:], proxySubmissions: [:], temporaryHostKeys: [:], trustPolicy: .allowChallenge
            )
        }
        #expect(library.sshCredentials(for: identity).accessUnavailable == nil)
    }

    @Test func silentProxyReadKeepsItsOwnerAndDoesNotBecomeAnAuthenticationFailure() throws {
        let secrets = RecoveryTestSecrets()
        secrets.unavailable = true
        let identity = Identity(name: "Proxy", username: "proxy", credentialRef: "password")
        let library = HostLibraryModel(identities: [identity], secrets: secrets)
        let node = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Target", host: "target.invalid", port: 22,
            authentication: SSHAuthenticationReference(username: "user", permitsNone: true),
            expectedHostKeys: [],
            proxy: .init(kind: .http, hostname: "proxy.invalid", port: 8080, username: "proxy", identityID: identity.id)
        )
        #expect(throws: SSHCredentialAccessUnavailable(hostID: node.id)) {
            try library.additionalConnectionRequest(from: SSHAdditionalConnectionSnapshot(target: node))
        }
    }

    @Test func interactionMarkerDoesNotHideAnUnavailableSavedPasswordFallback() throws {
        let secrets = RecoveryTestSecrets()
        secrets.unavailable = true
        let key = SSHKeyRef(
            label: "Touch ID", credentialRef: "protected", storage: .secureEnclave, requiresUserPresence: true)
        let identity = Identity(name: "User", username: "user", credentialRef: "password", keyID: key.id)
        let library = HostLibraryModel(keys: [key], identities: [identity], secrets: secrets)
        let node = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Target", host: "target.invalid", port: 22,
            authentication: SSHAuthenticationReference(identityID: identity.id, username: "user"),
            expectedHostKeys: [], proxy: nil)
        #expect(throws: SSHCredentialAccessUnavailable(hostID: node.id)) {
            try library.additionalConnectionRequest(from: SSHAdditionalConnectionSnapshot(target: node))
        }
    }
}

private nonisolated final class RecoveryTestSecrets: SecretStoring, @unchecked Sendable {
    private let backing = InMemorySecretStore()
    private let lock = NSLock()
    private var blocked = false
    private var keysBlocked = false
    private var passwordsBlocked = false
    var unavailable: Bool {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    var unavailableKeysOnly: Bool {
        get { lock.withLock { keysBlocked } }
        set { lock.withLock { keysBlocked = newValue } }
    }
    var unavailablePasswordsOnly: Bool {
        get { lock.withLock { passwordsBlocked } }
        set { lock.withLock { passwordsBlocked = newValue } }
    }
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        if unavailable || unavailablePasswordsOnly { throw SSHCredentialAccessUnavailable() }
        return try backing.string(for: account, storage: storage)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        if unavailable || unavailableKeysOnly { throw SSHCredentialAccessUnavailable() }
        return try backing.keyCredential(for: account, storage: storage)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try backing.setString(value, for: account, storage: storage)
    }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {
        try backing.setKeyCredential(value, for: account, storage: storage)
    }
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try backing.removePassword(account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        try backing.removeKeyCredential(account, storage: storage)
    }
}
