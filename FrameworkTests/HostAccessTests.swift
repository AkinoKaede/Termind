import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct HostAccessTests {
    private func fixtures(_ count: Int) -> [Host] {
        (0..<count).map {
            Host(
                name: "Host \($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)))
        }
    }

    @Test func initialEntitlementResolutionFinishesBeforeNewHostMutation() async throws {
        let library = HostLibraryModel(hosts: fixtures(3))
        library.hostAccess.entitlement = .loading
        var continuation: CheckedContinuation<Void, Never>?
        library.resolveInitialHostEntitlement = {
            await withCheckedContinuation { continuation = $0 }
            library.hostAccess.entitlement = .purchased(.purchased)
        }
        let added = Host(name: "New", host: "new.invalid")
        let operation = Task {
            try await library.resolveSavingHostsAccess([added])
            return library.saveHost(added)
        }
        defer { library.resolveInitialHostEntitlement = nil }
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(continuation != nil)
        #expect(library.hosts.count == 3)
        #expect(library.host(added.id) == nil)
        continuation?.resume()
        #expect(try await operation.value)
        #expect(library.host(added.id) != nil)
    }

    @Test func onlyExcessOperationsWaitForInitialEntitlement() async throws {
        let hosts = fixtures(4)
        let library = HostLibraryModel(hosts: hosts)
        library.hostAccess.entitlement = .loading
        var refreshes = 0
        library.resolveInitialHostEntitlement = {
            refreshes += 1
            library.hostAccess.entitlement = .purchased(.purchased)
        }
        defer { library.resolveInitialHostEntitlement = nil }
        try await library.resolveHostAccess(hosts[0])
        try await library.resolveSavingHostsAccess([hosts[3]])
        #expect(refreshes == 0)
        try await library.resolveHostAccess(hosts[3])
        #expect(refreshes == 1)
        try library.requireHostAccess(hosts[3])
    }

    @Test(arguments: [EntitlementStatus.free, .verificationFailed])
    func resolvedFreeAndFailedVerificationDoNotWriteAndOnlyFreePresentsUpgrade(status: EntitlementStatus) async {
        let library = HostLibraryModel(hosts: fixtures(3))
        library.hostAccess.entitlement = .loading
        var upgrades = 0
        library.requestHostUpgrade = { upgrades += 1 }
        library.resolveInitialHostEntitlement = { library.hostAccess.entitlement = status }
        defer { library.resolveInitialHostEntitlement = nil }
        let added = Host(name: "New", host: "new.invalid")
        do {
            try await library.resolveSavingHostsAccess([added])
            Issue.record("A non-Pro entitlement cannot admit another host")
        } catch {
            #expect((error as? HostAccessError) == (status == .free ? .hostLimit : .entitlementVerificationFailed))
        }
        #expect(library.hosts.count == 3)
        #expect(upgrades == (status == .free ? 1 : 0))
    }

    @Test func creationOrderIgnoresDisplayOrderAndPromotesAfterDeletion() {
        var hosts = fixtures(5)
        hosts[0].sortIndex = 99
        hosts[0].name = "Z"
        let policy = HostAccessPolicy(entitlement: .free)
        #expect(policy.unlockedIDs(in: Array(hosts.reversed())) == Set(hosts.prefix(3).map(\.id)))
        #expect(policy.isLocked(hosts[3].id, in: hosts))
        hosts.removeFirst()
        #expect(!policy.isLocked(hosts[2].id, in: hosts))
    }

    @Test func legacyOrderingIsStableAndPrecedesNewHosts() {
        var hosts = fixtures(5)
        for index in 0..<4 { hosts[index].createdAt = nil }
        let expected = Set(hosts.prefix(4).sorted { $0.id.uuidString < $1.id.uuidString }.prefix(3).map(\.id))
        let policy = HostAccessPolicy(entitlement: .free)
        #expect(policy.unlockedIDs(in: hosts) == expected)
        #expect(policy.unlockedIDs(in: Array(hosts.reversed())) == expected)
    }

    @Test func savedQuotaCountsDistinctAdditionsAndAllowsOverQuotaEditing() throws {
        let hosts = fixtures(4)
        let policy = HostAccessPolicy(entitlement: .free)
        try policy.requireSaving([hosts[0], hosts[0]], in: hosts)
        try policy.requireSaving([hosts[2], hosts[2]], in: Array(hosts.prefix(2)))
        #expect(throws: HostAccessError.hostLimit) {
            try policy.requireSaving([hosts[2], hosts[3]], in: Array(hosts.prefix(2)))
        }
        try HostAccessPolicy(entitlement: .purchased(.purchased)).requireSaving(hosts, in: [])
    }

    @Test func booleanSavePresentsQuotaWithoutAStorageError() {
        let library = HostLibraryModel(hosts: fixtures(3))
        library.hostAccess.entitlement = .free
        var upgrades = 0
        library.requestHostUpgrade = { upgrades += 1 }
        let added = Host(name: "New", host: "new.invalid")
        #expect(!library.saveHost(added))
        #expect(library.storageError == nil)
        #expect(library.host(added.id) == nil)
        #expect(upgrades == 1)
    }

    @Test func unresolvedEntitlementsDoNotShowLocksButPreventExcessOperations() {
        let hosts = fixtures(4)
        for status in [EntitlementStatus.loading, .verificationFailed] {
            let policy = HostAccessPolicy(entitlement: status)
            #expect(!policy.isLocked(hosts[3].id, in: hosts))
            #expect(throws: HostAccessError.self) { try policy.requireAccess(to: hosts[3].id, in: hosts) }
        }
    }

    @Test func writesAreRejectedBeforeCustomIdentityOrImportSideEffects() throws {
        let library = HostLibraryModel(hosts: fixtures(3))
        library.hostAccess.entitlement = .free
        var upgrades = 0
        library.requestHostUpgrade = { upgrades += 1 }
        var host = Host(name: "New", host: "new.invalid")
        var draft = HostCustomIdentityDraft()
        draft.sshUsername = "root"
        draft.sshPassword = "not-persisted"
        #expect(throws: HostAccessError.hostLimit) { try draft.save(into: &host, using: library) }
        #expect(library.identities.isEmpty)
        var batch = SSHImportBatch()
        batch.hosts = [host]
        batch.identities = [Identity(name: "Imported", username: "root")]
        #expect(throws: HostAccessError.hostLimit) { try library.commitSSHImport(batch) }
        #expect(library.hosts.count == 3)
        #expect(library.identities.isEmpty)
        #expect(upgrades == 2)
    }

    @Test func cachedAdmissionChecksTrackExpiryAndJumpHostLocks() throws {
        let hosts = fixtures(4)
        let library = HostLibraryModel(hosts: hosts)
        let check = try #require(library.connectionAccessCheck(for: [hosts[3].id]))
        try check()
        library.hostAccess.entitlement = .free
        #expect(throws: HostAccessError.lockedHost(hosts[3].id)) { try check() }
        var target = hosts[0]
        target.jumpHostID = hosts[3].id
        #expect(throws: HostAccessError.lockedHost(hosts[3].id)) { try library.requireHostAccess(target) }
        library.hostAccess.entitlement = .purchased(.purchased)
        try check()
    }

    @Test func localCreationStampsOnceAndCopiesGetANewDate() throws {
        let library = HostLibraryModel()
        var host = Host(name: "New", host: "new.invalid")
        #expect(library.saveHost(host))
        let original = try #require(library.host(host.id)?.createdAt)
        host.name = "Renamed"
        #expect(library.saveHost(host))
        #expect(library.host(host.id)?.createdAt == original)
        var copy = try #require(library.host(host.id))
        copy.id = UUID()
        copy.createdAt = .distantPast
        #expect(library.saveHost(copy))
        #expect(library.host(copy.id)?.createdAt != .distantPast)
    }

    @Test func preparedAliasRouteRetainsSavedAdmissionAfterExpiry() async throws {
        let hosts = fixtures(4)
        let library = HostLibraryModel(hosts: hosts)
        var alias = hosts[3]
        alias.id = UUID()
        let route = SSHConnectionRoute(hosts: [alias], sourceHostIDs: [alias.id: hosts[3].id])
        let preparation = try library.prepareSSHConnection(for: route, submissions: [:])
        let configuration = try await preparation.resolve(discoveryOnly: true)
        #expect(configuration.accessHostIDs.contains(hosts[3].id))
        try configuration.accessCheck?()
        library.hostAccess.entitlement = .free
        #expect(throws: HostAccessError.lockedHost(hosts[3].id)) { try configuration.accessCheck?() }
    }

    @Test func historicalStoreMigratesAndCreationDatesSurviveReopening() throws {
        let host = Host(name: "Legacy", host: "legacy.invalid")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        do {
            let schema = Schema(versionedSchema: TermindSchemaV57.self)
            let old = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none))
            old.mainContext.insert(TermindSchemaV56HostModels.PersistentHost(host))
            try old.mainContext.save()
        }
        let created = fixtures(1)[0]
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = HostPersistence(context: container.mainContext)
            #expect(try store.load().hosts == [host])
            _ = try store.save(.init(hosts: [host, created]))
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        let saved = try HostPersistence(context: reopened.mainContext).load().hosts
        #expect(saved.first(where: { $0.id == host.id })?.createdAt == nil)
        #expect(saved.first(where: { $0.id == created.id })?.createdAt == created.createdAt)
    }

    @Test func hostWireRetainsDatesAndRejectsLossyOldEncoding() throws {
        let host = fixtures(1)[0]
        let payload = VaultRecordPayload.host(host)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
        var old = envelope
        old.formatVersion = 7
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(old) }
        var legacy = host
        legacy.createdAt = nil
        old.payload = .host(legacy)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(old)) == old)
        var snapshot = VaultSnapshot(hosts: [host])
        try snapshot.apply(old)
        #expect(snapshot.hosts[0].createdAt == host.createdAt)
    }

    @Test func legacyRemoteUpdatesPreserveKnownDatesInBothProjectionAndJournal() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let host = fixtures(1)[0]
        container.mainContext.insert(PersistentHost(host))
        try container.mainContext.save()
        var legacy = host
        legacy.createdAt = nil
        legacy.name = "Updated by an older client"
        let payload = VaultRecordPayload.host(legacy)
        var envelope = VaultEnvelope(
            key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        envelope.formatVersion = 7
        let result = try HostPersistence(context: container.mainContext).applyRemote([envelope])
        #expect(result.snapshot.hosts.first?.name == legacy.name)
        #expect(result.snapshot.hosts.first?.createdAt == host.createdAt)
        #expect(result.needsUpload.contains(envelope.key))
        let pending = try VaultSyncJournal(context: container.mainContext).pendingEnvelopes()
        guard case .host(let saved) = pending.first(where: { $0.key == envelope.key })?.payload else {
            Issue.record("The repaired host date must be journaled for upload")
            return
        }
        #expect(saved.createdAt == host.createdAt)
    }
}
