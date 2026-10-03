import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct DeferredKeyMetadataTests {
    @Test func encryptedKeyWithoutKnownAlgorithmSurvivesStoreReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "vault.store")
        let key = SSHKeyRef(
            label: "Encrypted", algorithm: .unknown, credentialRef: "private-reference", hasPassphrase: true)
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let library = HostLibraryModel(persistence: HostPersistence(context: container.mainContext))
            try library.upsert(key)
        }
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let library = HostLibraryModel(persistence: HostPersistence(context: container.mainContext))
            let saved = try #require(library.key(key.id))
            #expect(saved.algorithm == .unknown && saved.hasPassphrase)
            #expect(saved.publicKey.isEmpty && saved.fingerprint.isEmpty)
        }
    }

    @Test func v3CarriesUnknownAlgorithmsAndLegacyWritersRejectThem() throws {
        let key = SSHKeyRef(
            label: "Encrypted", algorithm: .unknown, credentialRef: "private-reference", hasPassphrase: true)
        let payload = VaultRecordPayload.sshKey(key)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(envelope.formatVersion == 3)
        let decoded = try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope))
        guard case .sshKey(let roundTrip) = decoded.payload else {
            Issue.record("Missing key")
            return
        }
        #expect(roundTrip.algorithm == .unknown && roundTrip.hasPassphrase && roundTrip.publicKey.isEmpty)
        for version in [1, 2] {
            let legacy = VaultEnvelope(
                key: payload.key, version: envelope.version, payload: payload, formatVersion: version)
            #expect(throws: (any Error).self) { try VaultSyncCodec.encode(legacy) }
        }
    }

    @Test(arguments: [1, 2]) func legacyKeyRecordsRemainReadable(_ version: Int) throws {
        let key = SSHKeyRef(label: "Legacy", algorithm: .rsa, publicKey: "public", keySize: 3072, hasPassphrase: true)
        let payload = VaultRecordPayload.sshKey(key)
        let envelope = VaultEnvelope(
            key: payload.key, version: .baseline(writerID: UUID()), payload: payload, formatVersion: version)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)).payload == payload)
    }
}
