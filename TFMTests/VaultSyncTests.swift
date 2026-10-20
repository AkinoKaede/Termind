// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
        let connection = ConnectionHistoryEntry(
            hostID: host.id, kind: .ssh,
            sourceDeviceID: UUID(), endedAt: Date(timeIntervalSince1970: 30)
        )
        let sourceDevice = DeviceRecord(
            id: try #require(connection.sourceDeviceID), displayName: "Source Mac")
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
            .connectionHistory(connection), .device(sourceDevice),
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
    func connectionHistorySyncsDeviceMappingRenameEndTimeAndDeletion() throws {
        let source = try makeContainer("ConnectionHistorySource")
        let destination = try makeContainer("ConnectionHistoryDestination")
        let sourceHistoryRepository = SwiftDataConnectionHistoryRepository(context: source.mainContext)
        let sourceDeviceRepository = SwiftDataDeviceDirectoryRepository(context: source.mainContext)
        let sourceDeviceID = try HistorySyncJournal(context: source.mainContext).state().installationID
        let sourceDevices = DeviceDirectoryModel(
            repository: sourceDeviceRepository, currentDeviceID: sourceDeviceID,
            currentDeviceName: "Source Mac")
        let sourceModel = ConnectionHistoryModel(
            repository: sourceHistoryRepository, sourceDeviceID: sourceDeviceID)
        let hostID = UUID()
        let connectedAt = Date(timeIntervalSince1970: 10)
        let endedAt = Date(timeIntervalSince1970: 40)
        let entry = try #require(sourceModel.record(kind: .ssh, for: hostID, at: connectedAt))
        sourceModel.end(entry.id, at: endedAt)

        let key = HistoryRecordKey(kind: .connectionHistory, id: entry.id)
        let deviceKey = HistoryRecordKey(kind: .device, id: sourceModel.sourceDeviceID)
        let sourceJournal = HistorySyncJournal(context: source.mainContext)
        let envelope = try #require(try sourceJournal.envelope(for: key))
        let deviceEnvelope = try #require(try sourceJournal.envelope(for: deviceKey))
        _ = try HistorySyncPersistence(context: destination.mainContext).applyRemote(
            [envelope, deviceEnvelope])

        let received = try destination.mainContext.fetch(
            FetchDescriptor<PersistentConnectionHistoryEntry>()
        ).map(\.value)
        #expect(received.count == 1)
        #expect(received.first?.sourceDeviceID == sourceModel.sourceDeviceID)
        #expect(received.first?.connectedAt == connectedAt)
        #expect(received.first?.endedAt == endedAt)
        #expect(
            try destination.mainContext.fetch(
                FetchDescriptor<PersistentDeviceRecord>()
            ).map(\.value) == [
                DeviceRecord(
                    id: sourceModel.sourceDeviceID, displayName: "Source Mac")
            ])

        sourceDevices.updateCurrentDeviceName("Renamed Source Mac")
        let renamedDeviceEnvelope = try #require(try sourceJournal.envelope(for: deviceKey))
        _ = try HistorySyncPersistence(context: destination.mainContext).applyRemote(
            [renamedDeviceEnvelope])
        #expect(
            try destination.mainContext.fetch(
                FetchDescriptor<PersistentDeviceRecord>()
            ).map(\.displayName) == ["Renamed Source Mac"])

        sourceModel.delete(entry.id)
        let tombstone = try #require(try sourceJournal.envelope(for: key))
        #expect(tombstone.isDeleted)
        _ = try HistorySyncPersistence(context: destination.mainContext).applyRemote([tombstone])
        #expect(
            try destination.mainContext.fetchCount(
                FetchDescriptor<PersistentConnectionHistoryEntry>()) == 0)
    }

    @Test
    func existingConnectionHistoryBootstrapsAfterTheOriginalVaultBootstrap() throws {
        let container = try makeContainer("ConnectionHistoryBootstrap")
        let context = container.mainContext
        let persistence = HostPersistence(context: context)
        _ = try persistence.load()
        let sourceDevice = DeviceRecord(
            id: UUID(), displayName: "Source Phone")
        let entry = ConnectionHistoryEntry(
            hostID: UUID(), kind: .sftp, connectedAt: Date(timeIntervalSince1970: 5),
            sourceDeviceID: sourceDevice.id)
        context.insert(PersistentDeviceRecord(sourceDevice))
        context.insert(PersistentConnectionHistoryEntry(entry))
        try context.save()

        try HistorySyncPersistence(context: context).prepare()

        let key = HistoryRecordKey(kind: .connectionHistory, id: entry.id)
        let envelope = try #require(try HistorySyncJournal(context: context).envelope(for: key))
        #expect(envelope.payload == .connectionHistory(entry))
        let sourceDeviceEnvelope = try #require(
            try HistorySyncJournal(context: context).envelope(
                for: HistoryRecordKey(kind: .device, id: sourceDevice.id)))
        #expect(sourceDeviceEnvelope.payload == .device(sourceDevice))
        #expect(
            try context.fetch(FetchDescriptor<PersistentHistorySyncEntry>())
                .first(where: { $0.recordName == key.recordName })?.needsUpload == true)
    }

    @Test
    func launchPrunesLegacyConnectionHistoryBeforeSyncBootstrap() throws {
        let container = try makeContainer("ConnectionHistoryLaunchPruning")
        let context = container.mainContext
        let values = (0..<505).map { index in
            ConnectionHistoryEntry(
                hostID: UUID(), kind: .ssh,
                connectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                sourceDeviceID: UUID()
            )
        }
        for value in values { context.insert(PersistentConnectionHistoryEntry(value)) }
        try context.save()

        try HistorySyncPersistence(context: context).prepare()

        let retained = try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
            .map(\.value)
            .sorted(by: ConnectionHistoryEntry.isNewer)
        let historyEnvelopes = try context.fetch(FetchDescriptor<PersistentHistorySyncEntry>())
            .compactMap(\.envelope)
            .filter { $0.key.kind == .connectionHistory }
        #expect(retained.map(\.id) == Array(values.suffix(ConnectionHistoryModel.limit).reversed()).map(\.id))
        #expect(historyEnvelopes.count == values.count)
        #expect(historyEnvelopes.filter(\.isDeleted).count == values.count - ConnectionHistoryModel.limit)
        #expect(Set(historyEnvelopes.filter { !$0.isDeleted }.map(\.key.id)) == Set(retained.map(\.id)))
    }

    @Test
    func launchTombstonesAllOverflowToPreventLegacyResurrection() throws {
        let container = try makeContainer("ConnectionHistoryOverflowJournal")
        let context = container.mainContext
        let values = (0...(ConnectionHistoryModel.limit + 1)).map { index in
            ConnectionHistoryEntry(
                hostID: UUID(), kind: .ssh,
                connectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                sourceDeviceID: UUID()
            )
        }
        for value in values { context.insert(PersistentConnectionHistoryEntry(value)) }
        let unsent = values[0]
        let uploaded = values[1]
        let unsentKey = HistoryRecordKey(kind: .connectionHistory, id: unsent.id)
        let uploadedKey = HistoryRecordKey(kind: .connectionHistory, id: uploaded.id)
        let journal = HistorySyncJournal(context: context)
        for value in [unsent, uploaded] {
            let envelope = HistoryEnvelope(
                key: HistoryRecordKey(kind: .connectionHistory, id: value.id),
                version: .baseline(writerID: UUID()), payload: .connectionHistory(value)
            )
            context.insert(
                try PersistentHistorySyncEntry(envelope: envelope, needsUpload: value == unsent)
            )
        }
        try journal.updateSystemFields(Data("cloud-fields".utf8), for: uploadedKey)
        let state = try journal.state()
        state.engineStateData = Data("stale-pending-history".utf8)
        try context.save()

        try HistorySyncPersistence(context: context).prepare()

        #expect(try journal.envelope(for: unsentKey)?.isDeleted == true)
        #expect(try journal.envelope(for: uploadedKey)?.isDeleted == true)
        #expect(try journal.state().engineStateData == Data("stale-pending-history".utf8))
        #expect(
            try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>())
                == ConnectionHistoryModel.limit)
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
    func explicitlyTouchingAnUnchangedIdentityAdvancesItsModificationDate() throws {
        let container = try makeContainer("TouchIdentity")
        let persistence = HostPersistence(context: container.mainContext)
        let identity = Identity(name: "Deploy", username: "deploy")
        let key = VaultRecordKey(kind: .identity, id: identity.id)
        let snapshot = VaultSnapshot(identities: [identity])
        _ = try persistence.save(snapshot)
        let journal = VaultSyncJournal(context: container.mainContext)
        let initial = try #require(try journal.envelope(for: key)?.version)

        let mutations = try persistence.save(snapshot, touching: [key])
        let touched = try #require(try journal.envelope(for: key)?.version)

        #expect(mutations.keys == [key])
        #expect(touched > initial)
        #expect(try persistence.modificationDates()[key] == touched.modifiedAt)
        #expect(try persistence.load().identities == [identity])
    }

    @Test
    func identityConfigurationEditsCreateVaultMutations() throws {
        let container = try makeContainer("IdentityConfigurationEdit")
        let persistence = HostPersistence(context: container.mainContext)
        var identity = Identity(name: "Deploy", username: "deploy")
        _ = try persistence.save(VaultSnapshot(identities: [identity]))
        identity.name = "Production Deploy"

        let mutations = try persistence.save(VaultSnapshot(identities: [identity]))

        #expect(mutations.keys == [VaultRecordKey(kind: .identity, id: identity.id)])
        let envelope = try #require(
            try VaultSyncJournal(context: container.mainContext).envelope(
                for: VaultRecordKey(kind: .identity, id: identity.id)
            )
        )
        if case .identity(let payload) = envelope.payload {
            #expect(payload.name == identity.name)
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
        let encoded = String(decoding: try VaultSyncCodec.encode(envelope), as: UTF8.self)
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
