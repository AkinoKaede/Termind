import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@Suite(.serialized)
@MainActor
struct IdentityCredentialUsageTests {
    @Test
    func connectionReadsUpdateUsageButAvailabilityChecksDoNot() throws {
        let keychain = InMemorySecretStore()
        let reference = "termind.password.\(UUID().uuidString)"
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: reference, passwordStorage: .thisDevice
        )
        let store = HostLibraryModel(identities: [identity], secrets: keychain)
        try keychain.setString("secret", for: reference, storage: .thisDevice)

        #expect(store.passwordAvailability(for: identity) == .available)
        #expect(store.identity(identity.id)?.lastUsedAt == nil)

        _ = store.sshCredentials(for: identity)
        #expect(store.identity(identity.id)?.lastUsedAt != nil)
    }

    @Test
    func missingConnectionSecretsDoNotUpdateUsage() {
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.missing", passwordStorage: .thisDevice
        )
        let store = HostLibraryModel(
            identities: [identity], secrets: InMemorySecretStore()
        )

        _ = store.sshCredentials(for: identity)

        #expect(store.identity(identity.id)?.lastUsedAt == nil)
    }

    @Test
    func privateKeyAvailabilityCheckDoesNotUpdateUsage() throws {
        let keychain = InMemorySecretStore()
        let key = SSHKeyRef(
            label: "Deploy", publicKey: "ssh-ed25519 test",
            credentialRef: "termind.key.availability"
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostLibraryModel(
            keys: [key], identities: [identity], secrets: keychain
        )
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "private")),
            for: key.credentialRef, storage: key.storage
        )

        #expect(store.keyAvailability(for: key) == .available)
        #expect(store.identity(identity.id)?.lastUsedAt == nil)
    }

    @Test(arguments: [
        StoredSSHKeyCredential.software(SSHPrivateKeySecret(privateKey: "private")),
        StoredSSHKeyCredential.secureEnclave(
            SecureEnclaveKeyCredential(dataRepresentation: Data("handle".utf8))
        ),
    ])
    func savedPrivateKeyReadsUpdateUsage(_ credential: StoredSSHKeyCredential) throws {
        let keychain = InMemorySecretStore()
        let key = SSHKeyRef(
            label: "Deploy", publicKey: "ssh-ed25519 test",
            credentialRef: "termind.key.\(UUID().uuidString)"
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostLibraryModel(
            keys: [key], identities: [identity], secrets: keychain
        )
        try keychain.setKeyCredential(
            credential, for: key.credentialRef, storage: key.storage
        )

        _ = store.sshCredentials(for: identity)

        #expect(store.identity(identity.id)?.lastUsedAt != nil)
    }

    @Test
    func routeCredentialReadsArePersistedOnceForTargetJumpAndProxy() throws {
        let keychain = InMemorySecretStore()
        let targetIdentity = Identity(
            name: "Target", username: "target",
            credentialRef: "password.target", passwordStorage: .thisDevice
        )
        let jumpIdentity = Identity(
            name: "Jump", username: "jump",
            credentialRef: "password.jump", passwordStorage: .thisDevice
        )
        let proxyIdentity = Identity(
            name: "Proxy", username: "proxy",
            credentialRef: "password.proxy", passwordStorage: .thisDevice
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
        let snapshot = VaultSnapshot(
            hosts: [jump, target],
            identities: [targetIdentity, jumpIdentity, proxyIdentity]
        )
        let persistence = CredentialAccessPersistence(snapshot: snapshot)
        let store = HostLibraryModel(persistence: persistence, secrets: keychain)
        for identity in snapshot.identities {
            try keychain.setString(
                "secret", for: identity.credentialRef, storage: identity.passwordStorage
            )
        }

        _ = try store.sshConnectionConfiguration(
            for: target, trustPolicy: .allowChallenge
        )

        let dates = snapshot.identities.compactMap { store.identity($0.id)?.lastUsedAt }
        #expect(dates.count == 3)
        #expect(Set(dates).count == 1)
        #expect(persistence.saveCount == 1)
    }

    @Test
    func usageDatesAreMonotonicAndFailedPersistenceRollsBack() {
        let identity = Identity(name: "Deploy", username: "deploy")
        let persistence = CredentialAccessPersistence(
            snapshot: VaultSnapshot(identities: [identity])
        )
        let store = HostLibraryModel(persistence: persistence)
        let newer = Date(timeIntervalSince1970: 200)

        store.recordIdentityCredentialAccess([identity.id, UUID()], at: newer)
        store.recordIdentityCredentialAccess(
            [identity.id], at: Date(timeIntervalSince1970: 100)
        )

        #expect(store.identity(identity.id)?.lastUsedAt == newer)
        #expect(persistence.saveCount == 1)

        persistence.failsSave = true
        store.recordIdentityCredentialAccess(
            [identity.id], at: Date(timeIntervalSince1970: 300)
        )
        #expect(store.identity(identity.id)?.lastUsedAt == newer)
        #expect(store.storageError != nil)
    }

    @Test
    func detachedPreparationPublishesCredentialUsageBackToTheLibrary() async throws {
        let keychain = InMemorySecretStore()
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "password.detached", passwordStorage: .thisDevice
        )
        let host = Host(
            name: "Server", host: "server.invalid", identityID: identity.id
        )
        let store = HostLibraryModel(
            hosts: [host], identities: [identity], secrets: keychain
        )
        try keychain.setString(
            "secret", for: identity.credentialRef, storage: identity.passwordStorage
        )

        let preparation = try store.prepareSSHConnection(for: host, submissions: [:])
        _ = try await preparation.resolve(trustPolicy: .allowChallenge)
        for _ in 0..<100 where store.identity(identity.id)?.lastUsedAt == nil {
            await Task.yield()
        }

        #expect(store.identity(identity.id)?.lastUsedAt != nil)
    }
}

@MainActor
private final class CredentialAccessPersistence: VaultPersisting {
    let snapshot: VaultSnapshot
    var saveCount = 0
    var failsSave = false

    init(snapshot: VaultSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> VaultSnapshot { snapshot }

    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        saveCount += 1
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        return .empty
    }

    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        VaultRemoteApplyResult(snapshot: snapshot, acceptedKeys: [], needsUpload: [])
    }
}
