// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
struct RepositoryOutboxTests {
    @Test
    func freshBaselineStoreReopensWithoutLosingVaultData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TermindBaseline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Termind.store")

        let host = Host(name: "Production", host: "prod.example")
        let group = HostGroup(name: "Servers")
        let identity = Identity(
            name: "Operator", username: "deploy", passwordStorage: .iCloud,
            colorTag: .orange
        )
        let key = SSHKeyRef(
            label: "Deployment", publicKey: "ssh-ed25519 AAAA baseline",
            fingerprint: "SHA256:baseline", credentialRef: "key-baseline",
            storage: .iCloud, colorTag: .purple
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
            let configuration = localModelConfiguration(
                "Baseline", schema: HostPersistence.schema, url: storeURL
            )
            let container = try ModelContainer(
                for: HostPersistence.schema, configurations: [configuration]
            )
            let context = container.mainContext
            context.insert(PersistentHost(host))
            context.insert(PersistentHostGroup(group))
            context.insert(PersistentIdentity(identity))
            context.insert(PersistentSSHKey(key))
            context.insert(PersistentKnownHost(knownHost))
            context.insert(PersistentSnippetPackage(package))
            context.insert(PersistentSnippet(snippet))
            context.insert(PersistentPortForwardingRule(rule))
            try context.save()
        }

        let configuration = localModelConfiguration(
            "Baseline", schema: HostPersistence.schema, url: storeURL
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
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
    }

    @Test
    func schemaV6MigratesKeysAndIdentitiesWithNoColor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialColorMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: TermindSchemaV6.self)
        let identity = Identity(name: "Legacy", username: "legacy")
        let key = SSHKeyRef(label: "Legacy Key", fingerprint: "SHA256:legacy")

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration(
                    "CredentialColorMigration", schema: legacySchema, url: storeURL
                )
            ]
        )
        legacyContainer?.mainContext.insert(
            TermindSchemaV6Models.PersistentIdentity(identity)
        )
        legacyContainer?.mainContext.insert(
            TermindSchemaV6Models.PersistentSSHKey(key)
        )
        try legacyContainer?.mainContext.save()
        legacyContainer = nil

        let migrated = try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [
                localModelConfiguration(
                    "CredentialColorMigration", schema: HostPersistence.schema,
                    url: storeURL
                )
            ]
        )

        let identities = try migrated.mainContext.fetch(FetchDescriptor<PersistentIdentity>())
        let keys = try migrated.mainContext.fetch(FetchDescriptor<PersistentSSHKey>())
        #expect(identities.map(\.value.colorTag) == [.none])
        #expect(keys.map(\.value.colorTag) == [.none])
    }

    @Test
    func invalidPersistedCredentialColorsFallBackToNone() throws {
        let container = try makeContainer("InvalidCredentialColors")
        let identity = PersistentIdentity(Identity(name: "Deploy", username: "deploy"))
        let key = PersistentSSHKey(SSHKeyRef(label: "Deploy Key"))
        identity.colorTag = "future-identity-color"
        key.colorTag = "future-key-color"
        container.mainContext.insert(identity)
        container.mainContext.insert(key)
        try container.mainContext.save()

        #expect(identity.value.colorTag == .none)
        #expect(key.value.colorTag == .none)
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
        let doomedSSH = Identity(
            name: "Jump", username: "deploy", ownerHostID: doomed.id, customPurpose: .ssh)
        let doomedProxy = Identity(
            name: "Jump Proxy", username: "proxy", ownerHostID: doomed.id, customPurpose: .proxy)
        let reusable = Identity(name: "Reusable", username: "shared")
        let retainedCustom = Identity(
            name: "App", username: "app", ownerHostID: dependent.id, customPurpose: .ssh)
        context.insert(PersistentHost(doomed))
        context.insert(PersistentHost(dependent))
        for identity in [doomedSSH, doomedProxy, reusable, retainedCustom] {
            context.insert(PersistentIdentity(identity))
        }
        context.insert(PersistentSnippet(snippet))
        context.insert(PersistentPortForwardingRule(rule))
        let connectionHistory = ConnectionHistoryEntry(hostID: doomed.id, kind: .ssh)
        context.insert(PersistentConnectionHistoryEntry(connectionHistory))
        try context.save()
        let repository = SwiftDataHostRepository(context: context)

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
        #expect(try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).isEmpty)
        let connectionHistoryEnvelope = try #require(
            try HistorySyncJournal(context: context).envelope(
                for: HistoryRecordKey(kind: .connectionHistory, id: connectionHistory.id)))
        #expect(connectionHistoryEnvelope.isDeleted)
        #expect(try context.fetch(FetchDescriptor<PersistentPendingDeletion>()).isEmpty)
        #expect(
            Set(try context.fetch(FetchDescriptor<PersistentIdentity>()).map(\.id))
                == [reusable.id, retainedCustom.id]
        )
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

    @Test
    func deletingHostPreservesItsIndependentKnownHostRecords() throws {
        let container = try makeContainer("IndependentKnownHosts")
        let context = container.mainContext
        let host = Host(name: "Removed", host: "shared.example")
        let remaining = Host(name: "Another Login", host: host.host)
        let trust = KnownHostEntry(hostname: host.host, fingerprint: "SHA256:trusted")
        context.insert(PersistentHost(host))
        context.insert(PersistentHost(remaining))
        context.insert(PersistentKnownHost(trust))
        try context.save()
        let repository = SwiftDataHostRepository(context: context)
        try repository.requestHostDeletion(host.id)
        try repository.clearReferencesForDeletedHost(host.id)
        try repository.finalizeHostDeletion(host.id)
        #expect(try repository.snapshot().value.hosts.map(\.id) == [remaining.id])
        #expect(try context.fetch(FetchDescriptor<PersistentKnownHost>()).map(\.value) == [trust])
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
