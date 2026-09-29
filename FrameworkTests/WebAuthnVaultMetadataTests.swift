import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct WebAuthnVaultMetadataTests {
    private func key() -> SSHKeyRef {
        SSHKeyRef(
            label: "", algorithm: .securityKey, publicKey: "public-key", fingerprint: "SHA256:metadata",
            storage: .external,
            securityKey: SecurityKeyCredential(
                credentialID: Data([1, 2, 3]), publicKeyX963: Data([4]) + Data(repeating: 7, count: 64),
                userVerification: .preferred), keySize: 256, requiresUserPresence: true)
    }

    @Test func connectionPreparationResolvesDestinationAndJumpWithoutKeychain() async throws {
        var draft = key()
        draft.label = "Personal YubiKey"
        let identity = Identity(name: "Hardware", username: "root", keyID: draft.id)
        let preparation = SSHConnectionPreparation(
            nodes: ["jump.invalid", "server.invalid"].map { hostname in
                SSHConnectionPreparation.Node(
                    host: Host(name: hostname, host: hostname, identityID: identity.id),
                    identity: identity, key: draft, submission: nil, trustedKeys: [], proxyIdentity: nil)
            }, secrets: NoKeychain())
        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        #expect(configuration.username == "root")
        guard case .securityKey(let destination, let destinationName) = configuration.credentials.first,
            case .securityKey(let jump, let jumpName) = configuration.jumps.first?.credentials.first
        else {
            Issue.record("Expected metadata-backed hardware credentials for both route nodes")
            return
        }
        #expect(destination == draft.securityKey && jump == draft.securityKey)
        #expect(destinationName == draft.label && jumpName == draft.label)
    }

    @Test func metadataPersistsSyncsAndResolvesWithoutKeychain() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        let library = HostLibraryModel(persistence: persistence, secrets: NoKeychain())
        let draft = key()
        try library.upsert(draft)
        let saved = try #require(library.key(draft.id))
        #expect(saved.label == "Security Key" && saved.credentialRef.isEmpty)
        #expect(saved.storage == .external)
        #expect(library.keyAvailability(for: saved) == .available)
        #expect(try library.keyCredential(for: saved) == nil)
        let reloaded = try #require(try persistence.load().keys.first)
        #expect(reloaded.securityKey == draft.securityKey)
        #expect(reloaded.storage == .external)
        let payload = VaultRecordPayload.sshKey(reloaded)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(envelope.formatVersion == 2)
        let decoded = try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope))
        #expect(decoded.payload == payload)
        let remoteContainer = try TermindPersistence.makeContainer(inMemory: true)
        let remote = HostPersistence(context: remoteContainer.mainContext)
        _ = try remote.applyRemote([decoded])
        let remoteLibrary = HostLibraryModel(persistence: remote, secrets: NoKeychain())
        var synced = try #require(remoteLibrary.key(saved.id))
        #expect(synced.storage == .external)
        guard case .securityKey(let resolved)? = try remoteLibrary.keySecretCredential(for: synced) else {
            Issue.record("Expected a Vault hardware reference")
            return
        }
        #expect(resolved == draft.securityKey)
        synced.securityKey?.userVerification = .required
        try remoteLibrary.upsert(synced)
        #expect(try remote.load().keys.first?.securityKey?.userVerification == .required)
        try remoteLibrary.delete(keyID: synced.id)
        #expect(try remote.load().keys.isEmpty)
    }

    @Test(arguments: [KeyStorage.thisDevice, .iCloud])
    func legacyHardwareStorageLoadsAsExternal(_ storage: KeyStorage) throws {
        var legacy = key()
        legacy.storage = storage
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let row = TermindSchemaV45KeyModels.PersistentSSHKey(legacy)
        container.mainContext.insert(row)
        try container.mainContext.save()
        let persistence = HostPersistence(context: container.mainContext)
        let restored = try #require(try persistence.load().keys.first)
        #expect(restored.storage == .external)
        #expect(restored.securityKey == legacy.securityKey)
        #expect(try JSONDecoder().decode(SSHKeyRef.self, from: JSONEncoder().encode(legacy)).storage == .external)
        let library = HostLibraryModel(secrets: NoKeychain())
        try library.upsert(legacy)
        #expect(library.key(legacy.id)?.storage == .external)
    }

    @Test func externalHardwareRetainsCompatibleVaultWireStorage() throws {
        let payload = VaultRecordPayload.sshKey(key())
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let data = try VaultSyncCodec.encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadJSON = try #require(json["payload"] as? [String: Any])
        let keyJSON = try #require(payloadJSON["sshKey"] as? [String: Any])
        let fields = try #require(keyJSON["_0"] as? [String: Any])
        #expect(fields["storage"] as? String == "thisDevice")
        #expect(try VaultSyncCodec.decode(data).payload == payload)
    }

    @Test func softwareKeysCannotUseExternalStorage() throws {
        let software = SSHKeyRef(label: "Invalid", storage: .external)
        let library = HostLibraryModel(secrets: NoKeychain())
        #expect(throws: (any Error).self) { try library.upsert(software) }
        #expect(library.keys.isEmpty)
        let payload = VaultRecordPayload.sshKey(software)
        for version in [1, 2] {
            let envelope = VaultEnvelope(
                key: payload.key, version: .baseline(writerID: UUID()), payload: payload, formatVersion: version)
            #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
        }
    }

    @Test func failedMetadataWritesAndDeletesRollBackWithoutKeychain() throws {
        let persistence = MetadataPersistence()
        let library = HostLibraryModel(persistence: persistence, secrets: NoKeychain())
        let draft = key()
        persistence.fails = true
        #expect(throws: (any Error).self) { try library.upsert(draft) }
        #expect(library.keys.isEmpty)
        persistence.fails = false
        try library.upsert(draft)
        let saved = try #require(library.key(draft.id))
        persistence.fails = true
        var update = saved
        update.securityKey?.userVerification = .required
        #expect(throws: (any Error).self) { try library.upsert(update) }
        #expect(library.key(saved.id) == saved)
        #expect(throws: (any Error).self) { try library.delete(keyID: saved.id) }
        #expect(library.key(saved.id) == saved)
    }

    @Test func version44SoftwareKeysSurviveSchemaUpgradeAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Vault.store")
        let software = SSHKeyRef(label: "Existing", credentialRef: "termind.key.existing")
        try writeVersion44(software, to: url)
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let persistence = HostPersistence(context: container.mainContext)
            #expect(try persistence.load().keys == [software])
        }
    }

    private func writeVersion44(_ key: SSHKeyRef, to url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV44.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(TermindSchemaV7Models.PersistentSSHKey(key))
        try container.mainContext.save()
    }
}

private final class NoKeychain: SecretStoring, @unchecked Sendable {
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        throw CocoaError(.fileReadNoPermission)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        throw CocoaError(.fileReadNoPermission)
    }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func removePassword(_ account: String, storage: PasswordStorage) throws { throw CocoaError(.fileWriteNoPermission) }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws { throw CocoaError(.fileWriteNoPermission) }
}

@MainActor private final class MetadataPersistence: VaultPersisting {
    var snapshot = VaultSnapshot()
    var fails = false
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        throw CocoaError(.coderInvalidValue)
    }
}
