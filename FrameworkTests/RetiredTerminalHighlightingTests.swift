// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import SQLite3
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct RetiredTerminalHighlightingTests {
    @Test(arguments: [46, 51])
    func upgradeDeletesHighlightStorageAndRetainsOtherPreferencesAfterReopening(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        let domain = "RetiredHighlightMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let value = Data("unreadable retired preferences".utf8)
        try autoreleasepool {
            try writeHistoricalStore(url, value: value, version: version)
        }
        #expect(try hasHighlightTable(url))
        try autoreleasepool {
            try prepareUpgradedStore(url, defaults: defaults)
        }
        try autoreleasepool {
            let reopened = try TermindPersistence.makeContainer(url: url)
            reopened.mainContext.autosaveEnabled = false
            let store = SettingsSyncPersistence(context: reopened.mainContext, defaults: defaults)
            #expect(try !store.loadTerminal().shellIntegration)
            #expect(try store.journal.envelope(for: legacyKey) == nil)
            #expect(try store.journal.outgoingEntry(for: legacyKey) == nil)
        }
        #expect(try !hasHighlightTable(url))
    }

    @Test func preparationRetiresPendingHighlightUploadsWithoutReplacingOtherPreferences() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "RetiredHighlightPending.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.saveTerminal(.init(shellIntegration: false))
        let envelope = SettingsEnvelope(
            key: legacyKey, version: .baseline(writerID: UUID()), isDeleted: true)
        let retired = try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: true)
        retired.envelopeData = Data("invalid old payload".utf8)
        container.mainContext.insert(retired)
        try container.mainContext.save()
        try store.prepare()
        #expect(try store.journal.envelope(for: legacyKey) == nil)
        #expect(try store.journal.outgoingEntry(for: legacyKey) == nil)
        #expect(try !store.loadTerminal().shellIntegration)
        #expect(try store.load().recordPayloads[legacyKey] == nil)
        #expect(try !store.journal.cloudRecords().contains { $0.mutation.recordName == legacyKey.recordName })
    }

    @Test func malformedHighlightRecordsAreIgnoredWhileOtherSettingsStillSync() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "RetiredHighlightSync.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let network = LifecycleNetwork()
        let coordinator = SettingsSyncCoordinator(
            persistence: store,
            secrets: AISecretStore(context: container.mainContext, keychain: InMemorySecretStore(), defaults: defaults),
            defaults: defaults, environmentIdentifier: "Test", makeTransport: { _, _ in network.transport })
        coordinator.start()
        await coordinator.lifecycle.operation?.value
        defer { coordinator.pause() }
        let zone = CKRecordZone.ID(zoneName: SettingsSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
        let retired = CKRecord(
            recordType: SettingsSyncCoordinator.terminalHighlightRecordType,
            recordID: .init(recordName: legacyKey.recordName, zoneID: zone))
        // Deliberately missing every required field: these must never reach validation.
        let payload = SettingsRecordPayload.terminal(.init(shellIntegration: false))
        let envelope = SettingsEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let active = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: envelope), recordID: .init(recordName: payload.key.recordName, zoneID: zone))
        try coordinator.receiveRemoteRecords([retired, active])
        // Conflict delivery bypasses normal type filtering, but retired records must still be ignored.
        try coordinator.receiveRemoteRecords([retired], isConflict: true)
        try coordinator.receiveRemoteRecords([], deletions: [retired.recordID])
        #expect(try !store.loadTerminal().shellIntegration)
        #expect(try store.journal.envelope(for: legacyKey) == nil)
        #expect(try store.journal.outgoingEntry(for: legacyKey) == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentCloudSyncQuarantine>()) == 0)
        #expect(!legacyKey.kind.participatesInSync)
    }

    private var legacyKey: SettingsRecordKey { .init(kind: .terminalHighlighting, id: "default") }

    private func writeHistoricalStore(_ url: URL, value: Data, version: Int) throws {
        let schema =
            version == 46
            ? Schema(versionedSchema: TermindSchemaV46.self) : Schema(versionedSchema: TermindSchemaV51.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [.init("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.autosaveEnabled = false
        container.mainContext.insert(try PersistentTerminalPreferences(.init(shellIntegration: false)))
        container.mainContext.insert(PersistentTerminalHighlightPreferences(data: value))
        try container.mainContext.save()
    }

    private func hasHighlightTable(_ url: URL) throws -> Bool {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        try #require(
            result == SQLITE_OK,
            "SQLite open returned \(result): \(String(cString: sqlite3_errmsg(database)))")
        let timeout = sqlite3_busy_timeout(database, 5_000)
        try #require(
            timeout == SQLITE_OK,
            "SQLite busy timeout returned \(timeout): \(String(cString: sqlite3_errmsg(database)))")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepare = sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND lower(name) LIKE '%terminalhighlight%'",
            -1, &statement, nil)
        try #require(
            prepare == SQLITE_OK,
            "SQLite prepare returned \(prepare): \(String(cString: sqlite3_errmsg(database)))")
        let step = sqlite3_step(statement)
        try #require(
            step == SQLITE_ROW || step == SQLITE_DONE,
            "SQLite step returned \(step): \(String(cString: sqlite3_errmsg(database)))")
        return step == SQLITE_ROW
    }

    private func prepareUpgradedStore(_ url: URL, defaults: UserDefaults) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        container.mainContext.autosaveEnabled = false
        try SettingsSyncPersistence(context: container.mainContext, defaults: defaults).prepare()
        try container.mainContext.save()
    }
}
