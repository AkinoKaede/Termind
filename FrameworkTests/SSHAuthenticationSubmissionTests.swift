import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SSHAuthenticationSubmissionTests {
    @Test(arguments: [String?.none, "", "supplied"])
    func selectedPasswordFallbackRecordsOnlySavedCredentialAccess(_ password: String?) throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", credentialRef: "password")
        let store = HostLibraryModel(identities: [identity], secrets: secrets)
        try secrets.setString("saved", for: identity.credentialRef, storage: identity.passwordStorage)

        let submission = try store.authenticationSubmission(
            username: "deploy", password: password, passphrase: "one-use", keyID: identity.keyID,
            selectedIdentity: identity)

        #expect(submission.password == (password ?? "saved"))
        #expect(submission.passphrase == "one-use")
        #expect(submission.identityID == identity.id)
        #expect((store.identity(identity.id)?.lastUsedAt != nil) == (password == nil))
        #expect(try store.passwordCredential(for: identity) == "saved")
    }

    @Test
    func customSubmissionDoesNotInheritTheHostsSavedPassword() throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Saved", username: "saved", credentialRef: "password")
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let store = HostLibraryModel(hosts: [host], identities: [identity], secrets: secrets)
        try secrets.setString("saved", for: identity.credentialRef, storage: identity.passwordStorage)

        let submission = try store.authenticationSubmission(
            username: "one-use", password: nil, passphrase: nil, keyID: nil, selectedIdentity: nil)

        #expect(submission.password == nil)
        #expect(submission.identityID == nil)
        #expect(store.host(host.id) == host)
        #expect(store.identity(identity.id) == identity)
    }

    @Test
    func failedPasswordReadThrowsButExplicitInputBypassesIt() throws {
        let identity = Identity(name: "Deploy", username: "deploy", credentialRef: "unreadable")
        let store = HostLibraryModel(identities: [identity], secrets: UnreadableAuthenticationSecrets())

        #expect(throws: CocoaError.self) {
            try store.authenticationSubmission(
                username: "deploy", password: nil, passphrase: nil, keyID: nil, selectedIdentity: identity)
        }
        let submission = try store.authenticationSubmission(
            username: "deploy", password: "supplied", passphrase: nil, keyID: nil, selectedIdentity: identity)
        #expect(submission.password == "supplied")
        #expect(store.identity(identity.id)?.lastUsedAt == nil)
    }

    @Test(arguments: [false, true])
    func selectingAnIdentityOnlyReplacesAnExplicitPassword(_ replace: Bool) throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", credentialRef: "password")
        let host = Host(name: "Server", host: "server.invalid")
        let store = HostLibraryModel(hosts: [host], identities: [identity], secrets: secrets)
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let supplied = replace ? "replacement" : nil
        let submission = try store.authenticationSubmission(
            username: "deploy", password: supplied, passphrase: "one-use", keyID: nil, selectedIdentity: identity)
        // An omitted edit must never write the resolved snapshot back over a newer secret.
        try secrets.setString("rotated", for: identity.credentialRef, storage: identity.passwordStorage)

        let updated = try store.saveAuthentication(
            submission, for: host, selectedIdentity: identity, suppliedPassword: supplied)

        #expect(updated.identityID == identity.id)
        #expect(store.host(host.id) == updated)
        #expect(store.identities.count == 1)
        #expect(try store.passwordCredential(for: identity) == (replace ? "replacement" : "rotated"))
    }

    @Test(arguments: [false, true], [String?.none, "replacement"])
    func customSaveReusesIdentityMetadataOrCreatesTheDefaultIdentity(_ existing: Bool, password: String?) throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(
            name: "Production", username: "old-user", credentialRef: "password", passwordStorage: .thisDevice,
            keyID: UUID(), notes: "Keep these notes", lastUsedAt: Date(timeIntervalSince1970: 100), colorTag: .blue)
        let host = Host(name: "Server", host: "server.invalid", identityID: existing ? identity.id : nil)
        let store = HostLibraryModel(hosts: [host], identities: existing ? [identity] : [], secrets: secrets)
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let keyID = UUID()
        let submission = try store.authenticationSubmission(
            username: "new-user", password: password, passphrase: "one-use", keyID: keyID, selectedIdentity: nil)

        let updated = try store.saveAuthentication(
            submission, for: host, selectedIdentity: nil, suppliedPassword: password)

        let saved = try #require(store.identity(for: updated))
        #expect(store.identities.count == 1)
        #expect(saved.username == "new-user")
        #expect(saved.keyID == keyID)
        #expect(saved.name == (existing ? identity.name : "new-user"))
        #expect(saved.passwordStorage == (existing ? .thisDevice : .iCloud))
        #expect(try store.passwordCredential(for: saved) == (password ?? (existing ? "old" : nil)))
        #expect(store.host(host.id) == updated)
        if existing {
            #expect(saved.id == identity.id)
            #expect(saved.notes == identity.notes)
            #expect(saved.lastUsedAt == identity.lastUsedAt)
            #expect(saved.colorTag == identity.colorTag)
            #expect(saved.credentialRef == identity.credentialRef)
        } else if password == nil {
            #expect(saved.credentialRef.isEmpty)
        }
    }

    @Test
    func identitySaveFailureRollsBackThePasswordAndLeavesHostUnassociatedUntilRetry() throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", credentialRef: "password")
        let host = Host(name: "Server", host: "server.invalid")
        let persistence = AuthenticationPersistence(snapshot: VaultSnapshot(hosts: [host], identities: [identity]))
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let submission = try store.authenticationSubmission(
            username: "deploy", password: "replacement", passphrase: nil, keyID: nil, selectedIdentity: identity)
        persistence.failsSave = true

        #expect(throws: TermindSSHError.self) {
            try store.saveAuthentication(
                submission, for: host, selectedIdentity: identity, suppliedPassword: "replacement")
        }
        #expect(store.host(host.id) == host)
        #expect(persistence.snapshot.hosts == [host])
        #expect(try store.passwordCredential(for: identity) == "old")

        persistence.failsSave = false
        let updated = try store.saveAuthentication(
            submission, for: host, selectedIdentity: identity, suppliedPassword: "replacement")
        #expect(store.host(host.id) == updated)
        #expect(updated.identityID == identity.id)
        #expect(try store.passwordCredential(for: identity) == "replacement")
    }
}

private struct UnreadableAuthenticationSecrets: SecretStoring {
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        throw CocoaError(.fileReadNoPermission)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {}
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? { nil }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {}
    func removePassword(_ account: String, storage: PasswordStorage) throws {}
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}

@MainActor
private final class AuthenticationPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var failsSave = false

    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
    func saveIdentityLastUsedAt(_ updates: [Identity.ID: Date]) throws {}
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        VaultRemoteApplyResult(snapshot: snapshot, acceptedKeys: [], needsUpload: [])
    }
}
