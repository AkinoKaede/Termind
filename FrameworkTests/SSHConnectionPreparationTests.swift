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

    private func makePreparation(
        identity: Identity, key: SSHKeyRef? = nil,
        secrets: any SecretStoring
    ) -> SSHConnectionPreparation {
        let host = Host(name: "Monitor", host: "example.invalid", identityID: identity.id)
        return SSHConnectionPreparation(
            nodes: [
                SSHConnectionPreparation.Node(
                    host: host, identity: identity, key: key, submission: nil,
                    trustedKeys: [], proxyIdentity: nil
                )
            ],
            secrets: secrets
        )
    }
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
