import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite
struct SSHConnectionPreparationTests {
    @Test @MainActor
    func journeyKeepsEachProxyOnThePreviousEndpointUntilSSHStarts() {
        let jump = Host(
            name: "Jump", host: "jump.invalid",
            proxy: HostProxy(hostname: "local-proxy.invalid", port: 1080))
        let host = Host(
            name: "Server", host: "server.invalid", jumpHostID: jump.id,
            proxy: HostProxy(hostname: "jump-proxy.invalid", port: 1080))
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [jump, host], purpose: .sshSession, username: "deploy")

        #expect(journey.endpoints.map(\.id) == [.local, .host(jump.id), .host(host.id)])
        journey.receive(.proxyConnecting(jump.id))
        #expect(journey.activeEndpointIndex == 0)
        journey.waitForProxyAuthentication(at: jump.id)
        #expect(journey.activeEndpointIndex == 0)
        #expect(journey.localRequirementEndpointIndex == 0)
        #expect(journey.waitsForProxyAuthentication)
        journey.resume()
        journey.receive(.proxyConnected(jump.id))
        #expect(journey.activeEndpointIndex == 0)
        #expect(journey.completedEndpointIndex == 0)
        journey.receive(.connecting(jump.id))
        journey.receive(.connected(jump.id))
        #expect(journey.completedEndpointIndex == 1)

        journey.receive(.proxyConnecting(host.id))
        #expect(journey.activeEndpointIndex == 1)
        journey.waitForProxyAuthentication(at: host.id)
        #expect(journey.activeEndpointIndex == 1)
        #expect(journey.localRequirementEndpointIndex == 1)
        journey.resume()
        journey.receive(.proxyConnected(host.id))
        #expect(journey.activeEndpointIndex == 1)
        #expect(journey.completedEndpointIndex == 1)
        journey.receive(.connecting(host.id))
        #expect(journey.activeEndpointIndex == 2)
        #expect(
            journey.logs.contains {
                $0.endpoint == journey.endpoints[0].name && $0.message == "Connecting to proxy"
            })
        #expect(journey.logs.contains { $0.endpoint == jump.name && $0.message == "Connecting to proxy" })
    }

    @Test
    func proxySubmissionSuppliesOneShotPasswordAndPreservesProxyUsername() async throws {
        let identity = Identity(name: "SSH", username: "deploy")
        let proxyIdentity = Identity(
            name: "Proxy", username: "identity-user", credentialRef: "proxy.missing")
        let host = Host(
            name: "Server", host: "server.invalid", identityID: identity.id,
            proxy: HostProxy(
                hostname: "proxy.invalid", username: "proxy-user", identityID: proxyIdentity.id))
        let preparation = SSHConnectionPreparation(
            nodes: [
                .init(
                    host: host, identity: identity, key: nil, submission: nil,
                    trustedKeys: [], proxyIdentity: proxyIdentity,
                    proxySubmission: SSHProxyAuthenticationSubmission(
                        username: "custom-proxy-user", password: "one-use"))
            ],
            secrets: MappedPreparationSecrets())

        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        #expect(configuration.proxy?.username == "custom-proxy-user")
        #expect(configuration.proxy?.ownerHostID == host.id)
        #expect(try #require(configuration.proxy?.password) == "one-use")
    }

    @Test
    func missingProxyPasswordReportsItsOwningHost() async {
        let identity = Identity(name: "SSH", username: "deploy")
        let proxyIdentity = Identity(
            name: "Proxy", username: "proxy", credentialRef: "proxy.missing")
        let host = Host(
            name: "Server", host: "server.invalid", identityID: identity.id,
            proxy: HostProxy(
                hostname: "proxy.invalid", username: "proxy", identityID: proxyIdentity.id))
        let preparation = SSHConnectionPreparation(
            nodes: [
                .init(
                    host: host, identity: identity, key: nil, submission: nil,
                    trustedKeys: [], proxyIdentity: proxyIdentity)
            ], secrets: MappedPreparationSecrets())

        do {
            _ = try await preparation.resolve(trustPolicy: .allowChallenge)
            Issue.record("Expected proxy authentication")
        } catch let error as TermindSSHError {
            #expect(error.isProxyAuthentication)
            #expect(error.routeHostID == host.id)
            #expect(!error.isServerAuthenticationChallenge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func usernameOnlyIdentityReachesServerAuthentication() async throws {
        let preparation = makePreparation(
            identity: Identity(name: "OTP", username: "deploy"),
            secrets: PreparationSecrets(password: nil, key: nil)
        )
        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        #expect(configuration.username == "deploy")
        #expect(configuration.credentials.isEmpty)
    }

    @Test func customUsernameOnlySubmissionDoesNotRequireTheHostsSavedPassword() async throws {
        var preparation = makePreparation(
            identity: Identity(name: "Saved", username: "saved", credentialRef: "saved-password"),
            secrets: PreparationSecrets(password: nil, key: nil)
        )
        preparation.nodes[0].submission = SSHAuthenticationSubmission(username: "otp-user")
        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        #expect(configuration.username == "otp-user")
        #expect(configuration.credentials.isEmpty)
    }

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
    func protectedKeyIsNotReadBeforePassphraseIsRequested() async {
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
        #expect(recorder.identityIDs.isEmpty)
        #expect(recorder.callCount == 0)
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
