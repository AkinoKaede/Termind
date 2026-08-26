import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct RepositoryOutboxTests {
    @Test
    func legacyICloudStorageNamesAreRewrittenWhenVaultLoads() throws {
        let container = try makeContainer("LegacyICloudStorageMigration")
        let context = container.mainContext
        let identity = PersistentIdentity(Identity(name: "Cloud", username: "cloud"))
        let key = PersistentSSHKey(SSHKeyRef(label: "Cloud Key"))
        let legacyValue = "iCloud" + "Keychain"
        identity.passwordStorage = legacyValue
        key.storage = legacyValue
        context.insert(identity)
        context.insert(key)
        try context.save()

        let snapshot = try HostPersistence(context: context).load()

        #expect(snapshot.identities.first?.passwordStorage == .iCloud)
        #expect(snapshot.keys.first?.storage == .iCloud)
        #expect(identity.passwordStorage == PasswordStorage.iCloud.rawValue)
        #expect(key.storage == KeyStorage.iCloud.rawValue)
    }

    @Test
    func versionThreeStorageNamesMigrateToThisDevice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TermindV3Migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Termind.store")
        let identity = Identity(
            name: "Legacy Identity", username: "legacy",
            credentialRef: "termind.password.legacy", passwordStorage: .thisDevice
        )
        let key = SSHKeyRef(
            label: "Legacy Key", publicKey: "ssh-ed25519 AAAA legacy",
            fingerprint: "SHA256:legacy", credentialRef: "termind.key.legacy",
            storage: .thisDevice
        )

        do {
            let schema = Schema(versionedSchema: TermindSchemaV3.self)
            let configuration = ModelConfiguration("Migration", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(TermindSchemaV3Models.PersistentIdentity(identity))
            let persistentKey = TermindSchemaV3Models.PersistentSSHKey(key)
            persistentKey.storage = "local" + "Keychain"
            context.insert(persistentKey)
            try context.save()
        }

        let schema = Schema(versionedSchema: TermindSchemaV5.self)
        let configuration = ModelConfiguration("Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema, migrationPlan: TermindMigrationPlan.self,
            configurations: [configuration]
        )
        let context = container.mainContext
        let migratedIdentity = try #require(
            context.fetch(FetchDescriptor<PersistentIdentity>()).first
        )
        let migratedKey = try #require(
            context.fetch(FetchDescriptor<PersistentSSHKey>()).first
        )

        #expect(migratedIdentity.value == identity)
        #expect(migratedIdentity.passwordStorage == PasswordStorage.thisDevice.rawValue)
        #expect(migratedKey.value == key)
        #expect(migratedKey.storage == KeyStorage.thisDevice.rawValue)
        #expect(migratedKey.certificate.isEmpty)
    }

    @Test
    func versionOneStoreMigratesToCurrentSchemaWithoutLosingData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TermindMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Termind.store")

        let host = Host(name: "Production", host: "prod.example")
        let group = HostGroup(name: "Servers")
        let identity = Identity(
            name: "Operator", username: "deploy", passwordStorage: .thisDevice
        )
        let key = SSHKeyRef(
            label: "Deployment", publicKey: "ssh-ed25519 AAAA migration",
            fingerprint: "SHA256:migration", credentialRef: "key-migration",
            storage: .thisDevice
        )
        let knownHost = KnownHostEntry(
            hostname: "prod.example", algorithm: .ed25519,
            fingerprint: "SHA256:known-host"
        )
        let package = SnippetPackage(name: "Operations")
        let snippet = Snippet(
            title: "Health", body: "uptime", packageID: package.id,
            targetHostIDs: [host.id]
        )
        let rule = PortForwardingRule(hostID: host.id)

        do {
            let schema = Schema(versionedSchema: TermindSchemaV1.self)
            let configuration = ModelConfiguration(
                "Migration", schema: schema, url: storeURL
            )
            let container = try ModelContainer(
                for: schema, configurations: [configuration]
            )
            let context = container.mainContext
            context.insert(PersistentHost(host))
            context.insert(PersistentHostGroup(group))
            context.insert(TermindSchemaV3Models.PersistentIdentity(identity))
            let persistentKey = TermindSchemaV3Models.PersistentSSHKey(key)
            persistentKey.storage = "local" + "Keychain"
            context.insert(persistentKey)
            context.insert(PersistentKnownHost(knownHost))
            context.insert(PersistentSnippetPackage(package))
            context.insert(PersistentSnippet(snippet))
            context.insert(PersistentPortForwardingRule(rule))
            try context.save()
        }

        let schema = Schema(versionedSchema: TermindSchemaV5.self)
        let configuration = ModelConfiguration(
            "Migration", schema: schema, url: storeURL
        )
        let container = try ModelContainer(
            for: schema, migrationPlan: TermindMigrationPlan.self,
            configurations: [configuration]
        )
        let context = container.mainContext

        #expect(try context.fetch(FetchDescriptor<PersistentHost>()).map(\.value) == [host])
        #expect(try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.value) == [group])
        #expect(try context.fetch(FetchDescriptor<PersistentIdentity>()).map(\.value) == [identity])
        #expect(try context.fetch(FetchDescriptor<PersistentSSHKey>()).map(\.value) == [key])
        #expect(
            try context.fetch(FetchDescriptor<PersistentKnownHost>()).map(\.value) == [knownHost]
        )
        #expect(
            try context.fetch(FetchDescriptor<PersistentSnippetPackage>()).map(\.value)
                == [package]
        )
        #expect(try context.fetch(FetchDescriptor<PersistentSnippet>()).map(\.value) == [snippet])
        #expect(
            try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()).map(\.value)
                == [rule]
        )
        #expect(try context.fetch(FetchDescriptor<PersistentOutboxJob>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistentPendingDeletion>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistentDatabaseMetadata>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistentCommandHistoryEntry>()).isEmpty)
    }

    @Test
    func repositoryPublishesMonotonicMutationSnapshots() async throws {
        let container = try makeContainer("RepositoryStream")
        let repository = SwiftDataHostRepository(context: container.mainContext)
        var iterator = repository.changes().makeAsyncIterator()
        let initial = try #require(await iterator.next())
        let host = Host(name: "Build", host: "build.example")

        try repository.upsertHost(host)
        let mutation = try #require(await iterator.next())

        #expect(mutation.revision > initial.revision)
        #expect(mutation.reason == .mutation)
        #expect(mutation.value.hosts.map(\.id) == [host.id])
    }

    @Test
    func hostDeletionPersistsMarkerAndCompleteOutboxAtomically() throws {
        let container = try makeContainer("DeletionOutbox")
        let context = container.mainContext
        let doomed = Host(name: "Jump", host: "jump.example")
        var dependent = Host(name: "App", host: "app.example")
        dependent.jumpHostID = doomed.id
        var snippet = Snippet(title: "Deploy", body: "deploy")
        snippet.targetHostIDs = [doomed.id, dependent.id]
        let rule = PortForwardingRule(hostID: doomed.id)
        context.insert(PersistentHost(doomed))
        context.insert(PersistentHost(dependent))
        context.insert(PersistentSnippet(snippet))
        context.insert(PersistentPortForwardingRule(rule))
        context.insert(
            PersistentCommandHistoryEntry(
                CommandHistoryEntry(hostID: doomed.id, command: "uptime")
            )
        )
        try context.save()
        let repository = SwiftDataHostRepository(context: context)

        #expect(
            try repository.deletionImpact(for: doomed.id)
                == HostDeletionImpact(
                    jumpHostReferences: 1, snippetReferences: 1, forwardingRules: 1
                )
        )
        try repository.requestHostDeletion(doomed.id)

        let hiddenSnapshot = try repository.snapshot()
        #expect(!hiddenSnapshot.value.hosts.contains { $0.id == doomed.id })
        let markers = try context.fetch(FetchDescriptor<PersistentPendingDeletion>())
        let jobs = try context.fetch(
            FetchDescriptor<PersistentOutboxJob>(sortBy: [SortDescriptor(\.handlerID)])
        )
        #expect(markers.map(\.entityID) == [doomed.id])
        #expect(jobs.map(\.handlerID) == HostDeletionOutbox.handlerIDs)
        #expect(Set(jobs.map(\.eventID)).count == 1)
        #expect(jobs.allSatisfy { $0.status == OutboxJobStatus.pending.rawValue })

        try repository.clearReferencesForDeletedHost(doomed.id)
        try repository.finalizeHostDeletion(doomed.id)

        let remainingHosts = try context.fetch(FetchDescriptor<PersistentHost>())
        #expect(remainingHosts.map(\.id) == [dependent.id])
        #expect(remainingHosts.first?.jumpHostID == nil)
        #expect(
            try context.fetch(FetchDescriptor<PersistentSnippet>()).first?.targetHostIDs
                == [dependent.id]
        )
        #expect(try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistentCommandHistoryEntry>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistentPendingDeletion>()).isEmpty)
    }

    @Test
    func persistentOutboxResetsInterruptedWorkAndRetriesFailures() throws {
        let container = try makeContainer("OutboxStates")
        let store = SwiftDataOutboxStore(context: container.mainContext)
        let job = OutboxJob(
            handlerID: "test", eventType: "test.event", payload: Data(),
            nextAttemptAt: Date(timeIntervalSince1970: 0)
        )
        try store.enqueue([job])
        #expect(try store.nextReady(at: Date())?.id == job.id)

        try store.markRunning(job.id)
        #expect(try store.nextReady(at: Date()) == nil)
        try store.resetInterruptedJobs()
        #expect(try store.nextReady(at: Date())?.attemptCount == 1)

        try store.markFailed(job.id, error: "offline", retryAt: nil)
        #expect(try store.nextReady(at: Date()) == nil)
        try store.retryFailedJob(job.id)
        #expect(try store.nextReady(at: Date())?.lastError == nil)
        try store.markSucceeded(job.id)
        #expect(try store.nextReady(at: Date()) == nil)
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            name, schema: HostPersistence.schema, isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
    }
}
