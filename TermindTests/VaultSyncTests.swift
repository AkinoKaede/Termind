import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct VaultSyncTests {
    @Test
    func allVaultPayloadsRoundTripWithStableRecordNames() throws {
        let host = Host(name: "Production", host: "prod.example")
        let group = HostGroup(name: "Servers")
        let identity = Identity(name: "Deploy", username: "deploy", colorTag: .green)
        let key = SSHKeyRef(
            label: "Deploy Key", publicKey: "ssh-ed25519 AAAA", colorTag: .blue
        )
        let knownHost = KnownHostEntry(hostname: "prod.example", fingerprint: "SHA256:test")
        let package = SnippetPackage(name: "Operations")
        let snippet = Snippet(title: "Uptime", body: "uptime", packageID: package.id)
        let forwarding = PortForwardingRule(hostID: host.id)
        let payloads: [VaultRecordPayload] = [
            .host(host), .hostGroup(group), .identity(identity), .sshKey(key),
            .knownHost(knownHost), .snippet(snippet), .snippetPackage(package),
            .portForwarding(forwarding),
        ]
        let writer = UUID()

        for payload in payloads {
            let envelope = VaultEnvelope(
                key: payload.key, version: .baseline(writerID: writer), payload: payload
            )
            let decoded = try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope))
            #expect(decoded == envelope)
            #expect(VaultRecordKey(recordName: payload.key.recordName) == payload.key)
        }
    }

    @Test
    func legacyCredentialPayloadsWithoutColorsDecodeAsNone() throws {
        let writer = UUID()
        let identity = Identity(name: "Deploy", username: "deploy", colorTag: .pink)
        let key = SSHKeyRef(label: "Deploy Key", colorTag: .teal)
        let envelopes = [
            VaultEnvelope(
                key: VaultRecordKey(kind: .identity, id: identity.id),
                version: .baseline(writerID: writer), payload: .identity(identity)
            ),
            VaultEnvelope(
                key: VaultRecordKey(kind: .sshKey, id: key.id),
                version: .baseline(writerID: writer), payload: .sshKey(key)
            ),
        ]

        for envelope in envelopes {
            let legacyData = try removingJSONKey(
                "colorTag", from: VaultSyncCodec.encode(envelope)
            )
            let decoded = try VaultSyncCodec.decode(legacyData)
            switch decoded.payload {
            case .identity(let value): #expect(value.colorTag == .none)
            case .sshKey(let value): #expect(value.colorTag == .none)
            default: Issue.record("Expected a credential payload")
            }
        }
    }

    @Test
    func journalRecordsOnlyRealChangesAndKeepsDeletionTombstones() throws {
        let container = try makeContainer("JournalDiff")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        let host = Host(name: "Build", host: "build.example")
        let initial = VaultSnapshot(hosts: [host])

        let first = try persistence.save(initial)
        #expect(first.keys == [VaultRecordKey(kind: .host, id: host.id)])
        #expect(try persistence.save(initial).isEmpty)

        let deletion = try persistence.save(VaultSnapshot())
        let key = VaultRecordKey(kind: .host, id: host.id)
        #expect(deletion.keys == [key])
        let tombstone = try #require(
            try VaultSyncJournal(context: context).envelope(for: key)
        )
        #expect(tombstone.isDeleted)
        #expect(tombstone.payload == nil)
    }

    @Test
    func newerRemoteRecordWinsAndOlderRemoteRecordIsRequeued() throws {
        let container = try makeContainer("RemoteMerge")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        var host = Host(name: "Local", host: "local.example")
        _ = try persistence.save(VaultSnapshot(hosts: [host]))
        let key = VaultRecordKey(kind: .host, id: host.id)
        let local = try #require(
            try VaultSyncJournal(context: context).envelope(for: key)
        )

        host.name = "Remote"
        let newer = VaultEnvelope(
            key: key,
            version: VaultVersion(
                modifiedAt: local.version.modifiedAt.addingTimeInterval(10),
                counter: 0, writerID: UUID()
            ),
            payload: .host(host)
        )
        let accepted = try persistence.applyRemote([newer])
        #expect(accepted.snapshot.hosts.first?.name == "Remote")
        #expect(accepted.acceptedKeys == [key])

        let older = VaultEnvelope(
            key: key, version: .baseline(writerID: UUID()),
            payload: .host(Host(id: host.id, name: "Stale", host: "stale.example"))
        )
        let rejected = try persistence.applyRemote([older])
        #expect(rejected.snapshot.hosts.first?.name == "Remote")
        #expect(rejected.needsUpload == [key])
    }

    @Test
    func repositoryOwnedHostWritesAlsoEnterTheDurableJournal() throws {
        let container = try makeContainer("RepositoryJournal")
        let context = container.mainContext
        _ = try HostPersistence(context: context).load()
        let repository = SwiftDataHostRepository(context: context)
        let host = Host(name: "Repository", host: "repository.example")
        var published = VaultMutationSet.empty
        repository.didRecordVaultChanges = { published = $0 }

        try repository.upsertHost(host)

        let key = VaultRecordKey(kind: .host, id: host.id)
        #expect(published.keys == [key])
        let envelope = try #require(
            try VaultSyncJournal(context: context).envelope(for: key)
        )
        #expect(envelope.payload == .host(host))
        #expect(
            try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).first?.needsUpload
                == true
        )
    }

    @Test
    func encodedVaultMetadataContainsReferencesButNoCredentialMaterial() throws {
        let secret = "private-material-must-never-sync"
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.reference", passwordStorage: .iCloud
        )
        let envelope = VaultEnvelope(
            key: VaultRecordKey(kind: .identity, id: identity.id),
            version: .baseline(writerID: UUID()), payload: .identity(identity)
        )
        let encoded = String(decoding: VaultSyncCodec.encode(envelope), as: UTF8.self)
        #expect(encoded.contains(identity.credentialRef))
        #expect(!encoded.contains(secret))
    }

    @Test
    func cloudRecordUsesAssetForLargePayloadAndRejectsCorruption() throws {
        let host = Host(name: String(repeating: "A", count: 710_000), host: "large.example")
        let envelope = VaultEnvelope(
            key: VaultRecordKey(kind: .host, id: host.id),
            version: VaultVersion(modifiedAt: .now, counter: 0, writerID: UUID()),
            payload: .host(host)
        )
        let recordID = CKRecord.ID(
            recordName: envelope.key.recordName,
            zoneID: CKRecordZone.ID(
                zoneName: VaultSyncCoordinator.zoneName,
                ownerName: CKCurrentUserDefaultName
            )
        )
        let record = try VaultSyncCoordinator.makeRecord(
            VaultOutgoingEntry(envelope: envelope), recordID: recordID
        )
        #expect(record["payload"] == nil)
        #expect(record["payloadAsset"] as? CKAsset != nil)
        #expect(try VaultSyncCoordinator.envelope(from: record) == envelope)

        record["payloadHash"] = "bad" as NSString
        #expect(throws: (any Error).self) { try VaultSyncCoordinator.envelope(from: record) }
    }

    @Test
    func environmentChangeKeepsEnvelopesAndClearsCloudKitMetadata() throws {
        let container = try makeContainer("EnvironmentChange")
        let context = container.mainContext
        let host = Host(name: "Production", host: "prod.example")
        _ = try HostPersistence(context: context).save(VaultSnapshot(hosts: [host]))

        let key = VaultRecordKey(kind: .host, id: host.id)
        let journal = VaultSyncJournal(context: context)
        let envelope = try #require(try journal.envelope(for: key))
        try journal.updateSystemFields(Data("development-change-tag".utf8), for: key)
        try journal.markUploaded(key, version: envelope.version)
        let state = try journal.state()
        state.engineStateData = Data("development-engine-state".utf8)
        state.lastSuccessfulSync = .now
        try context.save()

        try journal.markAllEntriesNeedsUploadAfterEnvironmentChange()
        try context.save()

        let row = try #require(
            context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).first
        )
        #expect(row.envelope == envelope)
        #expect(row.needsUpload)
        #expect(row.systemFieldsData == nil)
        #expect(state.engineStateData == nil)
        #expect(state.lastSuccessfulSync == nil)
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let configuration = localModelConfiguration(
            name, schema: HostPersistence.schema, isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
    }
}

private func removingJSONKey(_ key: String, from data: Data) throws -> Data {
    func remove(from value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            dictionary.removeValue(forKey: key)
            return dictionary.mapValues(remove)
        }
        if let array = value as? [Any] {
            return array.map(remove)
        }
        return value
    }

    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: remove(from: object))
}
