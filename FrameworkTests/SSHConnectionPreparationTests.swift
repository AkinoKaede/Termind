import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite
struct SSHConnectionPreparationTests {
    @Test
    func keychainFailureRemainsDistinctFromMissingCredential() async {
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.test"
        )
        let preparation = makePreparation(
            identity: identity,
            secrets: PreparationSecrets(password: nil, key: nil, failsPassword: true)
        )

        await #expect(throws: PreparationSecretError.self) {
            _ = try await preparation.resolve(trustPolicy: .allowChallenge)
        }
    }

    @Test
    func availablePasswordSurvivesPrivateKeyLookupFailure() async throws {
        let key = SSHKeyRef(
            label: "Deploy", publicKey: "ssh-ed25519 test",
            credentialRef: "termind.key.test"
        )
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.test", keyID: key.id
        )
        let preparation = makePreparation(
            identity: identity, key: key,
            secrets: PreparationSecrets(password: "fallback", key: nil, failsKey: true)
        )

        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        #expect(configuration.credentials.count == 1)
        guard case .password(let password) = configuration.credentials.first else {
            Issue.record("Expected the available password credential")
            return
        }
        #expect(password == "fallback")
    }

    @Test
    func absentSavedSecretStillReportsMissingCredential() async {
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.test"
        )
        let preparation = makePreparation(
            identity: identity,
            secrets: PreparationSecrets(password: nil, key: nil)
        )

        await #expect(throws: TermindSSHError.self) {
            _ = try await preparation.resolve(trustPolicy: .allowChallenge)
        }
    }

    @Test
    func reportsJumpAndProxyReadsEvenWhenTheTargetCredentialIsMissing() async {
        let jumpIdentity = Identity(
            name: "Jump", username: "jump", credentialRef: "password.jump"
        )
        let proxyIdentity = Identity(
            name: "Proxy", username: "proxy", credentialRef: "password.proxy"
        )
        let targetIdentity = Identity(
            name: "Target", username: "target", credentialRef: "password.target"
        )
        let jump = Host(
            name: "Jump", host: "jump.invalid", identityID: jumpIdentity.id,
            proxy: HostProxy(
                hostname: "proxy.invalid", username: "proxy",
                identityID: proxyIdentity.id
            )
        )
        let target = Host(
            name: "Target", host: "target.invalid", identityID: targetIdentity.id,
            jumpHostID: jump.id
        )
        let recorder = PreparationAccessRecorder()
        let preparation = SSHConnectionPreparation(
            nodes: [
                SSHConnectionPreparation.Node(
                    host: jump, identity: jumpIdentity, key: nil, submission: nil,
                    trustedKeys: [], proxyIdentity: proxyIdentity
                ),
                SSHConnectionPreparation.Node(
                    host: target, identity: targetIdentity, key: nil, submission: nil,
                    trustedKeys: [], proxyIdentity: nil
                ),
            ],
            secrets: MappedPreparationSecrets(
                passwords: [
                    jumpIdentity.credentialRef: "jump-secret",
                    proxyIdentity.credentialRef: "proxy-secret",
                ]
            ),
            credentialAccessHandler: { recorder.record($0, at: $1) }
        )

        await #expect(throws: TermindSSHError.self) {
            _ = try await preparation.resolve(trustPolicy: .allowChallenge)
        }
        #expect(recorder.identityIDs == [jumpIdentity.id, proxyIdentity.id])
        #expect(recorder.callCount == 1)
    }

    @Test
    func protectedKeyReadIsReportedBeforePassphraseIsRequested() async {
        let key = SSHKeyRef(
            label: "Protected", publicKey: "ssh-ed25519 test",
            credentialRef: "key.protected", hasPassphrase: true
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let recorder = PreparationAccessRecorder()
        let preparation = makePreparation(
            identity: identity, key: key,
            secrets: MappedPreparationSecrets(
                keys: [
                    key.credentialRef: .software(
                        SSHPrivateKeySecret(privateKey: "encrypted")
                    )
                ]
            ),
            credentialAccessHandler: { recorder.record($0, at: $1) }
        )

        await #expect(throws: TermindSSHError.self) {
            _ = try await preparation.resolve(trustPolicy: .allowChallenge)
        }
        #expect(recorder.identityIDs == [identity.id])
        #expect(recorder.callCount == 1)
    }

    @Test
    func inlinePasswordIsNotReportedAsSavedIdentityAccess() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let recorder = PreparationAccessRecorder()
        let preparation = SSHConnectionPreparation(
            nodes: [
                SSHConnectionPreparation.Node(
                    host: host, identity: identity, key: nil,
                    submission: SSHAuthenticationSubmission(
                        username: identity.username, password: "inline",
                        identityID: identity.id
                    ),
                    trustedKeys: [], proxyIdentity: nil
                )
            ],
            secrets: MappedPreparationSecrets(),
            credentialAccessHandler: { recorder.record($0, at: $1) }
        )

        _ = try await preparation.resolve(trustPolicy: .allowChallenge)

        #expect(recorder.identityIDs.isEmpty)
        #expect(recorder.callCount == 0)
    }

    private func makePreparation(
        identity: Identity, key: SSHKeyRef? = nil,
        secrets: any SecretStoring,
        credentialAccessHandler: SSHCredentialAccessHandler? = nil
    ) -> SSHConnectionPreparation {
        let host = Host(name: "Monitor", host: "example.invalid", identityID: identity.id)
        return SSHConnectionPreparation(
            nodes: [
                SSHConnectionPreparation.Node(
                    host: host, identity: identity, key: key, submission: nil,
                    trustedKeys: [], proxyIdentity: nil
                )
            ],
            secrets: secrets,
            credentialAccessHandler: credentialAccessHandler
        )
    }
}

private nonisolated final class PreparationAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIdentityIDs: Set<Identity.ID> = []
    private var recordedCallCount = 0

    var identityIDs: Set<Identity.ID> { lock.withLock { recordedIdentityIDs } }
    var callCount: Int { lock.withLock { recordedCallCount } }

    func record(_ identityIDs: Set<Identity.ID>, at date: Date) {
        lock.withLock {
            recordedIdentityIDs.formUnion(identityIDs)
            recordedCallCount += 1
        }
    }
}

private final class MappedPreparationSecrets: SecretStoring, @unchecked Sendable {
    private let passwords: [String: String]
    private let keys: [String: StoredSSHKeyCredential]

    init(
        passwords: [String: String] = [:],
        keys: [String: StoredSSHKeyCredential] = [:]
    ) {
        self.passwords = passwords
        self.keys = keys
    }

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        passwords[account]
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {}

    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential? {
        keys[account]
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {}

    func removePassword(_ account: String, storage: PasswordStorage) throws {}
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}

private enum PreparationSecretError: Error {
    case unavailable
}

private final class PreparationSecrets: SecretStoring, @unchecked Sendable {
    private let password: String?
    private let key: StoredSSHKeyCredential?
    private let failsPassword: Bool
    private let failsKey: Bool

    init(
        password: String?, key: StoredSSHKeyCredential?,
        failsPassword: Bool = false, failsKey: Bool = false
    ) {
        self.password = password
        self.key = key
        self.failsPassword = failsPassword
        self.failsKey = failsKey
    }

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        if failsPassword { throw PreparationSecretError.unavailable }
        return password
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {}

    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential? {
        if failsKey { throw PreparationSecretError.unavailable }
        return key
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {}

    func removePassword(_ account: String, storage: PasswordStorage) throws {}
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}
