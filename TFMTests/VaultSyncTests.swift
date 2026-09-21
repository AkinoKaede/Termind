import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct VaultSyncTests {
    @Test
    func vaultModificationDatesTrackOnlyPersistedRecordChanges() async throws {
        let container = try makeContainer("ModificationDates")
        let persistence = HostPersistence(context: container.mainContext)
        var snippet = Snippet(title: "Uptime", body: "uptime")
        let initial = VaultSnapshot(snippets: [snippet])

        _ = try persistence.save(initial)
        let key = VaultRecordKey(kind: .snippet, id: snippet.id)
        let createdAt = try #require(try persistence.modificationDates()[key])
        #expect(createdAt > VaultVersion.baselineDate)

        _ = try persistence.save(initial)
        #expect(try persistence.modificationDates()[key] == createdAt)

        try await Task.sleep(for: .milliseconds(10))
        snippet.body = "uptime -p"
        _ = try persistence.save(VaultSnapshot(snippets: [snippet]))
        let editedAt = try #require(try persistence.modificationDates()[key])
        #expect(editedAt > createdAt)
    }

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
        let workspaceTemplate = WorkspaceTemplate(
            name: "Production",
            layout: .split(
                axis: .horizontal,
                fraction: 0.4,
                first: .pane(.ssh(hostID: host.id)),
                second: .pane(.empty)
            )
        )
        let payloads: [VaultRecordPayload] = [
            .host(host), .hostGroup(group), .identity(identity), .sshKey(key),
            .knownHost(knownHost), .snippet(snippet), .snippetPackage(package),
            .portForwarding(forwarding), .workspaceTemplate(workspaceTemplate),
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
    func importedKnownHostsSyncWithoutHostsAndPropagateEditsAndDeletion() throws {
        let source = try makeContainer("KnownHostsSource")
        let destination = try makeContainer("KnownHostsDestination")
        let sourcePersistence = HostPersistence(context: source.mainContext)
        let destinationPersistence = HostPersistence(context: destination.mainContext)
        let library = HostLibraryModel(persistence: sourcePersistence)
        let journal = VaultSyncJournal(context: source.mainContext)
        let hashedAddress =
            "|1|" + Data(repeating: 7, count: 20).base64EncodedString()
            + "|" + Data(repeating: 9, count: 20).base64EncodedString()
        let plain = KnownHostEntry(hostname: "sync.example", port: 2222, fingerprint: "SHA256:plain")
        let hashed = KnownHostEntry(hostname: hashedAddress, fingerprint: "SHA256:hashed")
        var published = VaultMutationSet.empty
        library.didRecordVaultChanges = { published = $0 }

        try library.commitSSHImport(SSHImportBatch(knownHosts: [plain, hashed]))
        #expect(published.keys == Set([plain, hashed].map { VaultRecordKey(kind: .knownHost, id: $0.id) }))
        #expect(try source.mainContext.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).allSatisfy(\.needsUpload))

        func transfer(_ id: UUID) throws {
            let key = VaultRecordKey(kind: .knownHost, id: id)
            let envelope = try #require(try journal.envelope(for: key))
            let recordID = CKRecord.ID(
                recordName: key.recordName,
                zoneID: CKRecordZone.ID(
                    zoneName: VaultSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName))
            let record = try VaultSyncCoordinator.makeRecord(VaultOutgoingEntry(envelope: envelope), recordID: recordID)
            let received = try VaultSyncCoordinator.envelope(from: record)
            _ = try destinationPersistence.applyRemote([received])
        }

        try transfer(plain.id)
        try transfer(hashed.id)
        let received = try destinationPersistence.load()
        #expect(received.hosts.isEmpty)
        #expect(Set(received.knownHosts) == Set([plain, hashed]))

        var edited = plain
        edited.algorithm = .ecdsa256
        #expect(library.saveKnownHost(edited))
        try transfer(plain.id)
        #expect(try destinationPersistence.load().knownHosts.first { $0.id == plain.id }?.algorithm == .ecdsa256)

        #expect(library.deleteKnownHosts([plain.id]))
        try transfer(plain.id)
        #expect(try destinationPersistence.load().knownHosts == [hashed])
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
    func libraryExpansionMetadataNeverChangesVaultRecords() throws {
        let container = try makeContainer("LocalLibraryExpansion")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        var group = HostGroup(name: "Production", isExpanded: false)
        var package = SnippetPackage(name: "Operations", isExpanded: false)
        let groupKey = VaultRecordKey(kind: .hostGroup, id: group.id)
        let packageKey = VaultRecordKey(kind: .snippetPackage, id: package.id)

        let initial = try persistence.save(
            VaultSnapshot(groups: [group], snippetPackages: [package])
        )
        #expect(initial.keys == [groupKey, packageKey])
        let journal = VaultSyncJournal(context: context)
        if case .hostGroup(let payload) = try journal.envelope(for: groupKey)?.payload {
            #expect(payload.isExpanded)
        } else {
            Issue.record("Expected a Host Group payload")
        }
        if case .snippetPackage(let payload) = try journal.envelope(for: packageKey)?.payload {
            #expect(payload.isExpanded)
        } else {
            Issue.record("Expected a Snippet Package payload")
        }

        group.isExpanded = true
        package.isExpanded = true
        #expect(
            try persistence.save(
                VaultSnapshot(groups: [group], snippetPackages: [package])
            ).isEmpty
        )

        var remoteGroup = group
        remoteGroup.isExpanded = false
        var remotePackage = package
        remotePackage.isExpanded = false
        let remoteVersion = VaultVersion(
            modifiedAt: Date().addingTimeInterval(60), counter: 0, writerID: UUID()
        )
        let result = try persistence.applyRemote([
            VaultEnvelope(key: groupKey, version: remoteVersion, payload: .hostGroup(remoteGroup)),
            VaultEnvelope(
                key: packageKey, version: remoteVersion,
                payload: .snippetPackage(remotePackage)
            ),
        ])

        #expect(result.snapshot.groups.first?.isExpanded == true)
        #expect(result.snapshot.snippetPackages.first?.isExpanded == true)
    }

    @Test
    func identityUsageStaysLocalAndDoesNotCreateVaultMutations() throws {
        let container = try makeContainer("LocalIdentityUsage")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        let identity = Identity(name: "Deploy", username: "deploy")
        let key = VaultRecordKey(kind: .identity, id: identity.id)
        _ = try persistence.save(VaultSnapshot(identities: [identity]))
        let journal = VaultSyncJournal(context: context)
        let initial = try #require(try journal.envelope(for: key))
        try journal.markUploaded(key, version: initial.version)
        try context.save()

        let usedAt = Date(timeIntervalSince1970: 500)
        try persistence.saveIdentityLastUsedAt([identity.id: usedAt])

        #expect(try persistence.load().identities.first?.lastUsedAt == usedAt)
        #expect(try journal.pendingEnvelopes().isEmpty)
        #expect(try journal.envelope(for: key)?.version == initial.version)
        if case .identity(let payload) = try journal.envelope(for: key)?.payload {
            #expect(payload.lastUsedAt == nil)
        } else {
            Issue.record("Expected an Identity payload")
        }
    }

    @Test
    func lastUsedOnlySnapshotSaveDoesNotAdvanceIdentityEnvelope() throws {
        let container = try makeContainer("LastUsedOnlySnapshot")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        var identity = Identity(name: "Deploy", username: "deploy")
        let key = VaultRecordKey(kind: .identity, id: identity.id)
        _ = try persistence.save(VaultSnapshot(identities: [identity]))
        let initial = try #require(try VaultSyncJournal(context: context).envelope(for: key))
        identity.lastUsedAt = Date(timeIntervalSince1970: 800)

        let mutations = try persistence.save(VaultSnapshot(identities: [identity]))

        #expect(mutations.isEmpty)
        #expect(try VaultSyncJournal(context: context).envelope(for: key)?.version == initial.version)
        #expect(try persistence.load().identities.first?.lastUsedAt == identity.lastUsedAt)
    }

    @Test
    func remoteIdentityPreservesLocalUsageAndStillAppliesConfiguration() throws {
        let container = try makeContainer("RemoteIdentityUsage")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        let identity = Identity(name: "Deploy", username: "deploy")
        let key = VaultRecordKey(kind: .identity, id: identity.id)
        _ = try persistence.save(VaultSnapshot(identities: [identity]))
        let localEnvelope = try #require(try VaultSyncJournal(context: context).envelope(for: key))
        let localUsage = Date(timeIntervalSince1970: 400)
        try persistence.saveIdentityLastUsedAt([identity.id: localUsage])

        var remoteIdentity = identity
        remoteIdentity.name = "Remote Deploy"
        remoteIdentity.lastUsedAt = Date(timeIntervalSince1970: 900)
        let remote = VaultEnvelope(
            key: key,
            version: VaultVersion(
                modifiedAt: localEnvelope.version.modifiedAt.addingTimeInterval(10),
                counter: 0, writerID: UUID()
            ),
            payload: .identity(remoteIdentity)
        )

        let result = try persistence.applyRemote([remote])

        #expect(result.snapshot.identities.first?.name == remoteIdentity.name)
        #expect(result.snapshot.identities.first?.lastUsedAt == localUsage)
        if case .identity(let payload) = try VaultSyncJournal(context: context).envelope(for: key)?.payload {
            #expect(payload.lastUsedAt == nil)
        } else {
            Issue.record("Expected an Identity payload")
        }
    }

    @Test
    func legacyPendingIdentityUsageIsRemovedBeforeUpload() throws {
        let container = try makeContainer("LegacyPendingIdentityUsage")
        let context = container.mainContext
        let identity = Identity(
            name: "Deploy", username: "deploy",
            lastUsedAt: Date(timeIntervalSince1970: 700)
        )
        let envelope = VaultEnvelope(
            key: VaultRecordKey(kind: .identity, id: identity.id),
            version: .baseline(writerID: UUID()), payload: .identity(identity)
        )
        context.insert(try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true))
        try context.save()

        let journal = VaultSyncJournal(context: context)
        let outgoing = try #require(try journal.outgoingEntry(for: envelope.key))
        if case .identity(let payload) = outgoing.envelope.payload {
            #expect(payload.lastUsedAt == nil)
        } else {
            Issue.record("Expected an Identity payload")
        }
        #expect(try journal.pendingEnvelopes() == [outgoing.envelope])
    }

    @Test
    func identityConfigurationEditsStillCreateVaultMutations() throws {
        let container = try makeContainer("IdentityConfigurationEdit")
        let persistence = HostPersistence(context: container.mainContext)
        var identity = Identity(
            name: "Deploy", username: "deploy",
            lastUsedAt: Date(timeIntervalSince1970: 100)
        )
        _ = try persistence.save(VaultSnapshot(identities: [identity]))
        identity.name = "Production Deploy"
        identity.lastUsedAt = Date(timeIntervalSince1970: 200)

        let mutations = try persistence.save(VaultSnapshot(identities: [identity]))

        #expect(mutations.keys == [VaultRecordKey(kind: .identity, id: identity.id)])
        let envelope = try #require(
            try VaultSyncJournal(context: container.mainContext).envelope(
                for: VaultRecordKey(kind: .identity, id: identity.id)
            )
        )
        if case .identity(let payload) = envelope.payload {
            #expect(payload.name == identity.name)
            #expect(payload.lastUsedAt == nil)
        } else {
            Issue.record("Expected an Identity payload")
        }
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
