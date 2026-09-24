import CloudKit
import CryptoKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct SFTPSettingsSyncTests {
    @Test(arguments: [nil, 3, 80] as [Int?])
    func importsExistingValuesOnlyOnce(global: Int?) throws {
        let fixture = try Fixture(global: global, perHost: global == nil ? nil : 2)
        defer { fixture.cleanUp() }
        let expected = SFTPPreferences(globalLimit: global ?? 30, perHostLimit: global == nil ? 10 : 2)
        #expect(try fixture.store.loadSFTP() == expected)
        #expect(fixture.defaults.integer(forKey: SettingsKey.sftpGlobalTransferLimit) == expected.globalLimit)
        let original = try #require(try fixture.store.journal.envelope(for: key))
        #expect(original.version.modifiedAt == VaultVersion.baselineDate)
        fixture.defaults.set(9, forKey: SettingsKey.sftpGlobalTransferLimit)
        try fixture.store.prepare()
        #expect(try fixture.store.loadSFTP() == expected)
        #expect(try fixture.store.journal.envelope(for: key) == original)
    }

    @Test func completedBootstrapAddsSFTPWithoutRewritingOtherRecords() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let previous = try fixture.store.journal.pendingEnvelopes().filter { $0.key != key }
        try fixture.container.mainContext.delete(
            model: PersistentAIConfigurationSyncEntry.self, where: #Predicate { $0.kind == "sftp" })
        try fixture.container.mainContext.delete(model: PersistentSFTPPreferences.self)
        try fixture.container.mainContext.save()
        fixture.defaults.set(3, forKey: SettingsKey.sftpGlobalTransferLimit)
        fixture.defaults.set(2, forKey: SettingsKey.sftpPerHostTransferLimit)
        try fixture.store.prepare()
        let added = try #require(try fixture.store.journal.envelope(for: key))
        #expect(added.payload == .sftp(SFTPPreferences(globalLimit: 3, perHostLimit: 2)))
        #expect(added.version.modifiedAt == VaultVersion.baselineDate)
        for record in previous { #expect(try fixture.store.journal.envelope(for: record.key) == record) }
    }

    @Test func settingsRoundTripAndRemoteApplicationDoesNotQueueAnEcho() throws {
        let source = try Fixture()
        let destination = try Fixture(global: 3, perHost: 2)
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        var localChanges: [SettingsMutationSet] = []
        source.store.didRecordChanges = { localChanges.append($0) }
        let value = SFTPPreferences(globalLimit: 100, perHostLimit: 50, strategy: .connectionsPreferred)
        try source.store.saveSFTP(value)
        #expect(localChanges.last?.keys == [key])
        let outgoing = try #require(try source.store.journal.envelope(for: key))
        let record = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: outgoing), recordID: recordID)
        #expect(record.recordType == SettingsSyncCoordinator.sftpRecordType)
        #expect(record.recordType != SettingsSyncCoordinator.recordType)
        #expect(SettingsSyncCoordinator.acceptsRecordType(record.recordType))
        #expect(SettingsSyncCoordinator.acceptsRecordType(SettingsSyncCoordinator.recordType))
        #expect(!SettingsSyncCoordinator.acceptsRecordType("UnknownSettingsItem"))
        let decoded = try SettingsSyncCoordinator.envelope(from: record)
        var callbacks = 0
        destination.store.didRecordChanges = { _ in callbacks += 1 }
        let result = try destination.store.applyRemote([decoded])
        #expect(result.snapshot.sftp == value)
        #expect(try destination.store.loadSFTP() == value)
        #expect(destination.defaults.integer(forKey: SettingsKey.sftpGlobalTransferLimit) == 100)
        #expect(destination.defaults.integer(forKey: SettingsKey.sftpPerHostTransferLimit) == 50)
        #expect(
            destination.defaults.string(forKey: SettingsKey.sftpConcurrencyStrategy)
                == SFTPConcurrencyStrategy.connectionsPreferred.rawValue)
        #expect(callbacks == 0)
        #expect(result.acceptedKeys == [key])
        #expect(try !destination.store.journal.pendingEnvelopes().contains { $0.key == key })
    }

    @Test func offlineEditsConvergeAsOnePairRegardlessOfDeliveryOrder() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.cleanUp()
            second.cleanUp()
        }
        try first.store.saveSFTP(.init(globalLimit: 30, perHostLimit: 10))
        try second.store.saveSFTP(.init(globalLimit: 80, perHostLimit: 40))
        let a = try #require(try first.store.journal.envelope(for: key))
        let b = try #require(try second.store.journal.envelope(for: key))
        let firstResult = try first.store.applyRemote([a, b])
        let secondResult = try second.store.applyRemote([b, a])
        #expect(firstResult.snapshot.sftp == secondResult.snapshot.sftp)
        #expect(try first.store.journal.envelope(for: key) == second.store.journal.envelope(for: key))
        #expect([a.payload, b.payload].contains(.sftp(firstResult.snapshot.sftp)))
    }

    @Test func olderSnapshotsWithoutSFTPDoNotResetTheCurrentLimits() throws {
        let fixture = try Fixture(global: 60, perHost: 20)
        defer { fixture.cleanUp() }
        let payload = SettingsRecordPayload.webSearch(.init(isEnabled: false))
        let result = try fixture.store.applyRemote([
            SettingsEnvelope(key: payload.key, version: .next(after: nil, writerID: UUID()), payload: payload)
        ])
        #expect(result.snapshot.sftp == SFTPPreferences(globalLimit: 60, perHostLimit: 20))
    }

    @Test(arguments: [
        "{\"globalLimit\":101,\"perHostLimit\":5}", "{\"globalLimit\":100,\"perHostLimit\":51}",
        "{\"globalLimit\":3,\"perHostLimit\":5}", "{\"globalLimit\":0,\"perHostLimit\":0}",
    ])
    func invalidRemoteValuesAreRejectedBeforeChangingPersistence(json: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let value = try JSONDecoder().decode(SFTPPreferences.self, from: Data(json.utf8))
        let invalid = SettingsEnvelope(key: key, version: .next(after: nil, writerID: UUID()), payload: .sftp(value))
        #expect(!invalid.isValid)
        let bytes = try JSONEncoder().encode(invalid)
        let record = CKRecord(recordType: SettingsSyncCoordinator.sftpRecordType, recordID: recordID)
        record["payload"] = bytes as NSData
        record["payloadHash"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() as NSString
        #expect(throws: SettingsSyncPersistenceError.self) { try SettingsSyncCoordinator.envelope(from: record) }
        #expect(
            try CloudSyncRecordCoding.payloadData(
                from: record, invalidEnvelope: SettingsSyncPersistenceError.invalidEnvelope(recordID.recordName))
                == bytes)
        #expect(throws: SettingsSyncPersistenceError.self) { try fixture.store.applyRemote([invalid]) }
        #expect(try fixture.store.loadSFTP() == SFTPPreferences())
        #expect(fixture.defaults.integer(forKey: SettingsKey.sftpGlobalTransferLimit) == 30)
    }

    @Test func cloudRecordTypeMustMatchItsPayloadAndRestoredSystemFields() throws {
        let envelope = SettingsEnvelope(key: key, version: .next(after: nil, writerID: UUID()), payload: .sftp(.init()))
        let record = try SettingsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: recordID)
        let wrong = CKRecord(recordType: SettingsSyncCoordinator.recordType, recordID: recordID)
        for field in record.allKeys() { wrong[field] = record[field] }
        #expect(throws: SettingsSyncPersistenceError.self) { try SettingsSyncCoordinator.envelope(from: wrong) }
        let fields = try CloudSyncRecordCoding.systemFields(of: wrong)
        #expect(throws: SettingsSyncPersistenceError.self) {
            try SettingsSyncCoordinator.makeRecord(
                .init(envelope: envelope, systemFieldsData: fields), recordID: recordID)
        }
    }

    @Test func failedLocalTransactionLeavesPreferencesDefaultsAndJournalUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let before = try fixture.store.journal.envelope(for: key)
        // Corrupt an unrelated configuration row so snapshot loading fails inside the transaction.
        let terminal = try #require(
            try fixture.container.mainContext.fetch(
                FetchDescriptor<PersistentTerminalPreferences>()
            ).first)
        terminal.data = Data("invalid".utf8)
        try fixture.container.mainContext.save()
        var callbacks = 0
        fixture.store.didRecordChanges = { _ in callbacks += 1 }
        #expect(throws: (any Error).self) { try fixture.store.saveSFTP(.init(globalLimit: 100, perHostLimit: 50)) }
        #expect(try fixture.store.loadSFTP() == SFTPPreferences())
        #expect(try fixture.store.journal.envelope(for: key) == before)
        #expect(fixture.defaults.integer(forKey: SettingsKey.sftpGlobalTransferLimit) == 30)
        #expect(callbacks == 0)
    }

    @Test func installedV20StoreMigratesAndPreservesItsSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Store.sqlite")
        let oldSchema = Schema(versionedSchema: TermindSchemaV20.self)
        var old: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none))
        let terminal = TerminalPreferences(darkTheme: "Catppuccin Mocha")
        old!.mainContext.insert(try PersistentTerminalPreferences(terminal))
        try old!.mainContext.save()
        old = nil
        let migrated = try TermindPersistence.makeContainer(url: url)
        let domain = "SFTPMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsKey.sftpGlobalTransferLimit)
        defaults.set(2, forKey: SettingsKey.sftpPerHostTransferLimit)
        let store = SettingsSyncPersistence(context: migrated.mainContext, defaults: defaults)
        try store.prepare()
        #expect(try store.loadTerminal() == terminal)
        #expect(try store.loadSFTP() == SFTPPreferences(globalLimit: 3, perHostLimit: 2))
        #expect(try migrated.mainContext.fetchCount(FetchDescriptor<PersistentSFTPPreferences>()) == 1)
    }

    private var key: SettingsRecordKey { .init(kind: .sftp, id: "default") }
    private var recordID: CKRecord.ID {
        .init(recordName: key.recordName, zoneID: .init(zoneName: SettingsSyncCoordinator.zoneName))
    }

    private struct Fixture {
        let domain = "SFTPSettingsSync.\(UUID())"
        let container: ModelContainer
        let defaults: UserDefaults
        let store: SettingsSyncPersistence

        init(global: Int? = nil, perHost: Int? = nil) throws {
            container = try TermindPersistence.makeContainer(inMemory: true)
            defaults = try #require(UserDefaults(suiteName: domain))
            if let global { defaults.set(global, forKey: SettingsKey.sftpGlobalTransferLimit) }
            if let perHost { defaults.set(perHost, forKey: SettingsKey.sftpPerHostTransferLimit) }
            store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
            try store.prepare()
        }

        func cleanUp() { defaults.removePersistentDomain(forName: domain) }
    }
}
