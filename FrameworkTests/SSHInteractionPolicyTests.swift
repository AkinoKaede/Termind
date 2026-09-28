import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SSHInteractionPolicyTests {
    @Test func allSecurityKeysRequireInteractionRegardlessOfUPIncludingJumps() {
        let silent = SecurityKeyCredential(credentialID: Data([1]), publicKeyX963: Data(), requiresUserPresence: false)
        let touching = SecurityKeyCredential(credentialID: Data([2]), publicKeyX963: Data(), requiresUserPresence: true)
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "fixture.invalid", port: 22, username: "user",
            credentials: [.securityKey(silent), .securityKey(touching)], expectedHostKeys: [],
            jumps: [
                .init(
                    id: UUID(), name: "Jump", host: "jump.invalid", port: 22, username: "user",
                    credentials: [.securityKey(silent), .securityKey(touching)], expectedHostKeys: [])
            ])
        let request = SSHConnectionRequest(configuration: configuration, interactionPolicy: .forbidden)
            .enforcingInteractionPolicy()
        for credentials in [request.configuration.credentials, request.configuration.jumps[0].credentials] {
            guard case .interactionRequired = credentials[0], case .interactionRequired = credentials[1] else {
                Issue.record("Every security key must be blocked during silent authentication")
                return
            }
        }
    }

    @Test func forbiddenPolicyCannotInvokeExplicitOrFallbackForms() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "example.invalid", port: 22, username: "user", credentials: [], expectedHostKeys: [])
        let request = SSHConnectionRequest(
            configuration: configuration,
            authorizeHostKey: { _ in
                Issue.record("Host key form must not open")
                return .accept
            },
            keyboardInteractive: queue.handler, interactionPolicy: .forbidden
        ).withKeyboardInteractiveFallback(queue.handler).enforcingInteractionPolicy()
        let handler = try #require(request.keyboardInteractive)
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: configuration.hostID, hostname: configuration.host,
            port: 22, username: "user", round: 1, name: "OTP", instruction: "",
            prompts: [.init(text: "Code", echo: false)])
        await #expect(throws: SSHInteractionRequired.self) { try await handler(challenge) }
        #expect(queue.pending.isEmpty)
        let authorize = try #require(request.authorizeHostKey)
        await #expect(throws: SSHInteractionRequired.self) {
            try await authorize(
                SSHHostKeyChallenge(
                    hostID: configuration.hostID,
                    observation: SSHHostKeyObservation(
                        hostname: configuration.host, port: 22, algorithm: .ed25519, fingerprint: "new"),
                    expectedHostKeys: []))
        }
    }

    @Test func additionalSnapshotRetainsRouteAndIDsWithoutCredentialMaterial() {
        let host = Host(name: "Server", host: "example.invalid")
        let jump = Host(name: "Jump", host: "jump.invalid")
        let identityID = UUID()
        let keyID = UUID()
        let trusted = KnownHostEntry(hostname: host.host, port: 22, algorithm: .ed25519, fingerprint: "saved")
        let store = HostLibraryModel(hosts: [host, jump], knownHosts: [trusted])
        let configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: 22, username: "temporary-user",
            credentials: [.password("temporary-password")], expectedHostKeys: [],
            jumps: [
                SSHRouteHopConfiguration(
                    id: jump.id, name: jump.name, host: jump.host, port: 22, username: "jump-user", credentials: [],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: "once-only")])
            ],
            authenticationReference: SSHAuthenticationReference(
                identityID: identityID, fallbackKeyID: keyID,
                username: "temporary-user"
            ))
        var withReference = configuration
        withReference.jumps[0].authenticationReference = SSHAuthenticationReference(
            fallbackKeyID: keyID, username: "jump-user", permitsNone: false
        )

        let additional = store.additionalConnectionSnapshot(from: withReference)
        #expect(additional.target.expectedHostKeys == [trusted.identity])
        #expect(additional.jumps[0].expectedHostKeys.isEmpty)
        #expect(additional.target.host == host.host)
        #expect(additional.target.authentication.username == "temporary-user")
        #expect(additional.target.authentication.identityID == identityID)
        #expect(additional.target.authentication.fallbackKeyID == keyID)
        #expect(additional.jumps[0].authentication.username == "jump-user")
        #expect(additional.jumps[0].authentication.fallbackKeyID == keyID)
    }

    @Test func forbiddenPolicyReplacesProtectedKeysButKeepsPasswordFallback() {
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "example.invalid", port: 22, username: "user",
            credentials: [
                .secureEnclave(
                    credential: SecureEnclaveKeyCredential(dataRepresentation: Data("handle".utf8)),
                    publicKey: "public", requiresUserPresence: true
                ),
                .privateKey(
                    privateKey: "encrypted", publicKey: "public", passphrase: "one-time",
                    requiresPassphrase: true
                ),
                .password("saved-password"),
            ], expectedHostKeys: [])

        let request = SSHConnectionRequest(
            configuration: configuration, interactionPolicy: .forbidden
        ).enforcingInteractionPolicy()
        #expect(request.configuration.credentials.count == 3)
        guard case .interactionRequired = request.configuration.credentials[0] else {
            Issue.record("Touch ID key must become an interaction marker")
            return
        }
        guard case .interactionRequired = request.configuration.credentials[1] else {
            Issue.record("Passphrase key must become an interaction marker")
            return
        }
        guard case .password(let password) = request.configuration.credentials[2] else {
            Issue.record("Password fallback must remain available")
            return
        }
        #expect(password == "saved-password")
    }

    @Test func additionalResolutionUsesCurrentIdentityAndSkipsProtectedKeyReads() throws {
        let secrets = CountingSecretStore()
        let protectedKey = SSHKeyRef(
            label: "Touch ID", publicKey: "ecdsa-sha2-nistp256 public",
            credentialRef: "key.touch-id", storage: .secureEnclave,
            requiresUserPresence: true
        )
        let fallbackKey = SSHKeyRef(
            label: "Fallback", publicKey: "ssh-ed25519 fallback",
            credentialRef: "key.fallback"
        )
        let identity = Identity(
            name: "Current", username: "current-user",
            credentialRef: "password.current", keyID: protectedKey.id
        )
        try secrets.setString("current-password", for: identity.credentialRef, storage: identity.passwordStorage)
        let store = HostLibraryModel(
            keys: [protectedKey, fallbackKey], identities: [identity], secrets: secrets
        )
        let node = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Server", host: "example.invalid", port: 22,
            authentication: SSHAuthenticationReference(
                identityID: identity.id, fallbackKeyID: fallbackKey.id,
                username: "stale-user"
            ),
            expectedHostKeys: [], proxy: nil
        )

        let request = try store.additionalConnectionRequest(
            from: SSHAdditionalConnectionSnapshot(target: node)
        )
        #expect(request.configuration.username == "current-user")
        #expect(secrets.keyReads == 0)
        #expect(secrets.stringReads == 1)
        guard case .interactionRequired = request.configuration.credentials[0] else {
            Issue.record("The current Identity key must take priority and remain unread")
            return
        }
        guard case .password(let password) = request.configuration.credentials[1] else {
            Issue.record("The current Identity password must remain available")
            return
        }
        #expect(password == "current-password")
    }

    @Test func additionalResolutionChecksForSavedPassphraseAndUsesIdentityPassword() throws {
        let secrets = CountingSecretStore()
        let protectedKey = SSHKeyRef(
            label: "Encrypted", publicKey: "ssh-ed25519 public",
            credentialRef: "key.encrypted", hasPassphrase: true
        )
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "password.deploy", keyID: protectedKey.id
        )
        try secrets.setString("saved-password", for: identity.credentialRef, storage: identity.passwordStorage)
        let store = HostLibraryModel(
            keys: [protectedKey], identities: [identity], secrets: secrets
        )
        let node = SSHAdditionalConnectionSnapshot.Node(
            id: UUID(), name: "Server", host: "example.invalid", port: 22,
            authentication: SSHAuthenticationReference(
                identityID: identity.id, username: "stale"
            ),
            expectedHostKeys: [], proxy: nil
        )

        let request = try store.additionalConnectionRequest(
            from: SSHAdditionalConnectionSnapshot(target: node)
        )
        #expect(secrets.keyReads == 1)
        guard case .interactionRequired = request.configuration.credentials[0] else {
            Issue.record("A key without a saved passphrase must require interaction")
            return
        }
        guard case .password(let password) = request.configuration.credentials[1] else {
            Issue.record("Identity password must remain available")
            return
        }
        #expect(password == "saved-password")
    }

    @Test func runtimeSecretCanBeConsumedOnlyOnceAcrossAllReferences() throws {
        var source = Data("one-use".utf8)
        let secret = SSHSecret(consumingUTF8: &source)
        let alias = secret
        var observedCount = 0

        #expect(source.isEmpty)

        try secret.withUnsafeCStringAndConsume { buffer, count in
            observedCount = count
            #expect(buffer[0] == CChar(bitPattern: Character("o").asciiValue!))
        }

        #expect(observedCount == 7)
        #expect(secret.isConsumed)
        #expect(alias.isConsumed)
        #expect(throws: SSHSecret.Consumed.self) {
            try alias.withUnsafeCStringAndConsume { _, _ in }
        }
    }

    @Test func clearingAConfigurationInvalidatesEveryCredentialCopy() {
        let password = SSHSecret("password")
        let privateKey = SSHSecret("private-key")
        let passphrase = SSHSecret("passphrase")
        let proxyPassword = SSHSecret("proxy-password")
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "example.invalid", port: 22, username: "user",
            credentials: [
                .password(password),
                .privateKey(
                    privateKey: privateKey, publicKey: nil,
                    passphrase: passphrase, requiresPassphrase: true
                ),
            ], expectedHostKeys: [],
            proxy: SSHTransportProxy(
                kind: .socks5, hostname: "proxy.invalid", port: 1080,
                username: "proxy", password: proxyPassword
            )
        )
        let copy = configuration

        copy.clearSecrets()

        #expect(password.isConsumed)
        #expect(privateKey.isConsumed)
        #expect(passphrase.isConsumed)
        #expect(proxyPassword.isConsumed)
        #expect(
            configuration.credentials.allSatisfy { credential in
                switch credential {
                case .password(let value): value.isConsumed
                case .privateKey(let value, _, let phrase, _):
                    value.isConsumed && phrase?.isConsumed == true
                case .securityKey, .secureEnclave, .interactionRequired: true
                }
            })
    }
}

private nonisolated final class CountingSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var keys: [String: StoredSSHKeyCredential] = [:]
    private(set) var stringReads = 0
    private(set) var keyReads = 0

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        lock.withLock {
            stringReads += 1
            return strings[account]
        }
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        lock.withLock { strings[account] = value }
    }

    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        lock.withLock {
            keyReads += 1
            return keys[account]
        }
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        lock.withLock { keys[account] = value }
    }

    func removePassword(_ account: String, storage: PasswordStorage) throws {
        lock.withLock { strings[account] = nil }
    }

    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        lock.withLock { keys[account] = nil }
    }
}
