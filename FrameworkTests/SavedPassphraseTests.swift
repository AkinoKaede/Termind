import Foundation
import Observation
import Synchronization
import TermindDomain
import Testing

@testable import TermindApplication

@Suite @MainActor
struct SavedPassphraseTests {
    @Test func keychainCardObservesSavingAndClearingThePassphrase() throws {
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostLibraryModel(identities: [identity], secrets: secrets)
        try store.upsert(key, credential: .software(.init(privateKey: "encrypted")))
        let credentials = CredentialLibraryModel(library: store)
        let changed = Mutex(false)
        withObservationTracking {
            #expect(!credentials.hasSavedPassphrase(for: key))
        } onChange: {
            changed.withLock { $0 = true }
        }
        try store.saveKeyPassphrase("saved", for: key.id)
        #expect(changed.withLock { $0 })
        #expect(credentials.hasSavedPassphrase(for: key))
        changed.withLock { $0 = false }
        withObservationTracking {
            #expect(credentials.hasSavedPassphrase(for: key))
        } onChange: {
            changed.withLock { $0 = true }
        }
        try store.upsert(key, credential: .software(.init(privateKey: "encrypted")))
        #expect(changed.withLock { $0 })
        #expect(!credentials.hasSavedPassphrase(for: key))
        #expect(store.requiresPassphraseEntry(for: key))
        let prompt = SSHAuthenticationPromptResolver.host(
            Host(name: "Host", host: "example.invalid", identityID: identity.id), using: store)
        #expect(prompt.requiresPassphrase)
        let reloaded = HostLibraryModel(keys: store.keys, secrets: secrets)
        #expect(reloaded.requiresPassphraseEntry(for: key))
    }

    @Test(arguments: [false, true], [false, true])
    func passphraseSaveIsExplicitAndPreservesStagedIdentity(save: Bool, allowsSaving: Bool) throws {
        let secrets = InMemorySecretStore()
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "Host", host: "example.invalid")
        let store = HostLibraryModel(hosts: [host], keys: [key], identities: [identity], secrets: secrets)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "encrypted")), for: key.credentialRef, storage: key.storage)
        let prompt = SSHAuthenticationPrompt(
            host: host, selectedIdentityID: identity.id, username: "deploy", selectedKeyID: key.id,
            requiresPassphrase: true, allowsSaving: allowsSaving)
        let staged = SSHAuthenticationSubmission(
            username: "deploy", password: "fallback", keyID: key.id, identityID: identity.id)
        let result = try store.passphraseSubmission(for: prompt, existing: staged, passphrase: "saved", save: save)
        #expect(result.password == "fallback")
        #expect(result.identityID == identity.id)
        #expect(result.keyID == key.id)
        #expect(result.passphrase == "saved")
        #expect(store.host(host.id) == host)
        #expect(store.identities == [identity])
        #expect(store.requiresPassphraseEntry(for: key) == !(save && allowsSaving))
        guard case .software(let credential)? = try secrets.keyCredential(for: key.credentialRef, storage: key.storage)
        else {
            Issue.record("Missing key")
            return
        }
        #expect(credential.passphrase == (save && allowsSaving ? "saved" : nil))
    }

    @Test func savingWithoutAStagedSubmissionDoesNotSaveTheHostIdentity() throws {
        let secrets = InMemorySecretStore()
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let store = HostLibraryModel(keys: [key], secrets: secrets)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "encrypted")), for: key.credentialRef, storage: key.storage)
        let host = Host(name: "Host", host: "example.invalid")
        let prompt = SSHAuthenticationPrompt(
            host: host, selectedIdentityID: nil, username: "deploy", selectedKeyID: key.id, requiresPassphrase: true)
        let result = try store.passphraseSubmission(for: prompt, existing: nil, passphrase: "saved", save: true)
        #expect(result.username == "deploy")
        #expect(store.hosts.isEmpty && store.identities.isEmpty)
        #expect(!store.requiresPassphraseEntry(for: key))
    }

    @Test func missingKeySaveFailsWithoutMutatingTheSubmission() {
        let store = HostLibraryModel()
        let keyID = UUID()
        let staged = SSHAuthenticationSubmission(username: "deploy", password: "fallback", keyID: keyID)
        let prompt = SSHAuthenticationPrompt(
            host: Host(name: "Host", host: "example.invalid"), selectedIdentityID: nil, username: "deploy",
            selectedKeyID: keyID, requiresPassphrase: true)
        #expect(throws: TermindSSHError.self) {
            _ = try store.passphraseSubmission(for: prompt, existing: staged, passphrase: "saved", save: true)
        }
        #expect(staged.passphrase == nil && staged.password == "fallback")
    }

    @Test func savedPassphrasesAllowSilentTargetAndJumpConnectionsAndAreReread() throws {
        let secrets = InMemorySecretStore()
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostLibraryModel(keys: [key], identities: [identity], secrets: secrets)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "encrypted", passphrase: "saved")), for: key.credentialRef, storage: key.storage
        )
        func node(_ name: String) -> SSHAdditionalConnectionSnapshot.Node {
            .init(
                id: UUID(), name: name, host: "example.invalid", port: 22,
                authentication: .init(identityID: identity.id, username: "deploy"), expectedHostKeys: [], proxy: nil)
        }
        let snapshot = SSHAdditionalConnectionSnapshot(target: node("Target"), jumps: [node("Jump")])
        let first = try store.additionalConnectionRequest(from: snapshot)
        defer { first.configuration.clearSecrets() }
        for credential in first.configuration.credentials + first.configuration.jumps.flatMap(\.credentials) {
            guard case .privateKey(_, _, let passphrase, let requiresEntry) = credential else {
                Issue.record("Saved passphrase must be usable silently")
                continue
            }
            #expect(!requiresEntry)
            #expect(passphrase?.matches("saved") == true)
        }
        #expect(
            SSHAuthenticationPromptResolver.host(
                Host(name: "Host", host: "example.invalid", identityID: identity.id), using: store
            ).requiresPassphrase == false)
        try store.saveKeyPassphrase("replacement", for: key.id)
        let second = try store.additionalConnectionRequest(from: snapshot)
        defer { second.configuration.clearSecrets() }
        guard case .privateKey(_, _, let passphrase, _) = second.configuration.credentials.first else {
            Issue.record("Expected refreshed key")
            return
        }
        #expect(passphrase?.matches("replacement") == true)
    }

    @Test func preparationUsesSavedPassphrasesWithoutPrompts() async throws {
        let secrets = InMemorySecretStore()
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "Host", host: "example.invalid", identityID: identity.id)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "encrypted", passphrase: "saved")), for: key.credentialRef, storage: key.storage
        )
        let preparation = SSHConnectionPreparation(
            nodes: [
                .init(host: host, identity: identity, key: key, submission: nil, trustedKeys: [], proxyIdentity: nil)
            ], secrets: secrets)
        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        defer { configuration.clearSecrets() }
        guard case .privateKey(_, _, let passphrase, let requiresEntry) = configuration.credentials.first else {
            Issue.record("Expected saved key")
            return
        }
        #expect(!requiresEntry && passphrase?.matches("saved") == true)
    }

    @Test(arguments: [false, true], [false, true])
    func clearingOrDeletingAKeyZeroesRollbackSecrets(delete: Bool, failsSave: Bool) throws {
        let observation = ZeroizedAllocations()
        let secrets = TrackedVaultSecrets(observation: observation)
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let persistence = PassphrasePersistence(snapshot: VaultSnapshot(keys: [key]))
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "encrypted", passphrase: "saved")), for: key.credentialRef, storage: key.storage
        )
        persistence.failsSave = failsSave
        do {
            if delete {
                try store.delete(keyID: key.id)
            } else {
                try store.upsert(key, credential: .software(.init(privateKey: "encrypted")))
            }
            #expect(!failsSave)
        } catch { #expect(failsSave) }
        #expect(observation.count == 2 && observation.allZero)
        let current = try secrets.keyCredential(for: key.credentialRef, storage: key.storage)
        if delete && !failsSave {
            #expect(current == nil && store.key(key.id) == nil)
        } else {
            guard case .software(let value)? = current else {
                Issue.record("Missing key")
                return
            }
            #expect(value.privateKey == "encrypted")
            #expect(value.passphrase == (failsSave ? "saved" : nil))
            #expect(store.key(key.id) != nil)
            #expect(store.key(key.id)?.hasPassphrase == true)
            #expect(store.requiresPassphraseEntry(for: key) == !failsSave)
        }
    }

    @Test func preparationFailureZeroesSavedSecretsEvenWhileAliasesRemainAlive() async {
        let observation = ZeroizedAllocations()
        let secrets = RetainedPreparationSecrets(observation: observation)
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "Host", host: "example.invalid", identityID: identity.id)
        let preparation = SSHConnectionPreparation(
            nodes: [
                .init(host: host, identity: identity, key: key, submission: nil, trustedKeys: [], proxyIdentity: nil)
            ], secrets: secrets)
        await #expect(throws: TermindSSHError.self) { _ = try await preparation.resolve() }
        #expect(secrets.key.isConsumed && secrets.passphrase.isConsumed)
        #expect(observation.count == 2 && observation.allZero)
    }

    @Test func cancellationAfterKeychainReadZeroesSavedSecrets() async {
        let observation = ZeroizedAllocations()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let secrets = RetainedPreparationSecrets(observation: observation) {
            continuation.yield(())
            gate.wait()
        }
        let key = SSHKeyRef(label: "Protected", credentialRef: "termind.key.fixture", hasPassphrase: true)
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "Host", host: "example.invalid", identityID: identity.id)
        let preparation = SSHConnectionPreparation(
            nodes: [
                .init(host: host, identity: identity, key: key, submission: nil, trustedKeys: [], proxyIdentity: nil)
            ], secrets: secrets)
        let task = Task { try await preparation.resolve(trustPolicy: .allowChallenge) }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        gate.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(observation.count == 2 && observation.allZero)
        continuation.finish()
    }

    @Test func replacedSavedPassphraseAndAllAttemptBuffersAreZeroedBeforeDeallocation() throws {
        let observation = ZeroizedAllocations()
        let key = SSHSecret("private-key")
        let saved = SSHSecret("saved-passphrase")
        let override = SSHSecret("override-passphrase")
        for secret in [key, saved, override] { secret.observeZeroization { observation.record($0) } }
        let credential = SSHResolvedKeyCredential.software(key, passphrase: saved).sshCredential(
            publicKey: "public", passphraseOverride: override, requiresPassphrase: true)
        #expect(observation.count == 1)
        credential.clearSecrets()
        #expect(observation.count == 3)
        #expect(observation.allZero)
    }

    @Test(arguments: [false, true])
    func consumingSavedPassphraseZeroesAllocationOnSuccessAndThrow(fails: Bool) throws {
        let observation = ZeroizedAllocations()
        let secret = SSHSecret("saved")
        secret.observeZeroization { observation.record($0) }
        do {
            try secret.withUnsafeCStringAndConsume { _, _ in
                if fails { throw CancellationError() }
            }
        } catch { #expect(fails && error is CancellationError) }
        #expect(observation.count == 1 && observation.allZero)
    }
}

private nonisolated final class ZeroizedAllocations: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    var count: Int { lock.withLock { observations.count } }
    var allZero: Bool { lock.withLock { observations.allSatisfy { $0 } } }
    func record(_ bytes: UnsafeRawBufferPointer) {
        lock.withLock { observations.append(!bytes.isEmpty && bytes.allSatisfy { $0 == 0 }) }
    }
}

private nonisolated final class RetainedPreparationSecrets: SSHRuntimeSecretResolving, Sendable {
    let key = SSHSecret("encrypted")
    let passphrase = SSHSecret("saved")
    let onRead: @Sendable () -> Void
    init(observation: ZeroizedAllocations, onRead: @escaping @Sendable () -> Void = {}) {
        self.onRead = onRead
        key.observeZeroization { observation.record($0) }
        passphrase.observeZeroization { observation.record($0) }
    }
    func sshSecret(for account: String, storage: PasswordStorage) throws -> SSHSecret? { nil }
    func sshKeyCredential(for account: String, storage: KeyStorage) throws -> SSHResolvedKeyCredential? {
        onRead()
        return .software(key, passphrase: passphrase)
    }
}

private nonisolated final class TrackedVaultSecrets: SecretStoring, Sendable {
    let base = InMemorySecretStore()
    let observation: ZeroizedAllocations
    init(observation: ZeroizedAllocations) { self.observation = observation }
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        try base.string(for: account, storage: storage)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try base.setString(value, for: account, storage: storage)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        try base.keyCredential(for: account, storage: storage)
    }
    func sshKeyCredential(for account: String, storage: KeyStorage) throws -> SSHResolvedKeyCredential? {
        let result = try base.sshKeyCredential(for: account, storage: storage)
        if case .software(let key, let passphrase) = result {
            key.observeZeroization { [observation] in observation.record($0) }
            passphrase?.observeZeroization { [observation] in observation.record($0) }
        }
        return result
    }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {
        try base.setKeyCredential(value, for: account, storage: storage)
    }
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try base.removePassword(account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        try base.removeKeyCredential(account, storage: storage)
    }
}

@MainActor private final class PassphrasePersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var failsSave = false
    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet {
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        VaultRemoteApplyResult(snapshot: snapshot, acceptedKeys: [], needsUpload: [])
    }
}
