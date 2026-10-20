// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct SSHSettingsTests {
    @Test
    func sessionLimitClampsOutOfRangeInputs() {
        #expect(SSHPreferences(maxSessions: 0).maxSessions == 1)
        #expect(SSHPreferences(maxSessions: 101).maxSessions == 100)
    }

    @Test
    func failedSavePreservesTheRuntimeValue() {
        let persistence = TestSSHPreferencesPersistence()
        let model = SSHSettingsModel(persistence: persistence)
        var received: [SSHPreferences] = []
        model.didChange = { received.append($0) }
        persistence.fail = true
        #expect(!model.set(20, for: \.maxSessions))
        #expect(model.preferences == SSHPreferences())
        #expect(received.isEmpty)

        persistence.fail = false
        #expect(model.set(20, for: \.maxSessions))
        #expect(persistence.value == SSHPreferences(maxSessions: 20))
        #expect(received == [SSHPreferences(maxSessions: 20)])
    }

    @Test
    func cloudRoundTripUsesAnOldClientSafeRecordType() throws {
        let source = try Fixture(maxSessions: 7)
        let destination = try Fixture(maxSessions: 3)
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        try source.store.saveSSH(SSHPreferences(maxSessions: 42))
        let key = SettingsRecordKey(kind: .ssh, id: "default")
        let outgoing = try #require(try source.store.journal.envelope(for: key))
        let recordID = CKRecord.ID(
            recordName: key.recordName,
            zoneID: .init(zoneName: SettingsSyncCoordinator.zoneName))
        let record = try SettingsSyncCoordinator.makeRecord(.init(envelope: outgoing), recordID: recordID)
        #expect(record.recordType == SettingsSyncCoordinator.sshRecordType)
        #expect(SettingsSyncCoordinator.acceptsRecordType(record.recordType))

        let result = try destination.store.applyRemote([SettingsSyncCoordinator.envelope(from: record)])
        #expect(result.snapshot.ssh == SSHPreferences(maxSessions: 42))
        #expect(try destination.store.loadSSH() == SSHPreferences(maxSessions: 42))
        #expect(destination.defaults.integer(forKey: SettingsKey.sshMaxSessions) == 42)
    }

    @Test
    func invalidRemoteValueIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let value = try JSONDecoder().decode(
            SSHPreferences.self, from: Data(#"{"maxSessions":0}"#.utf8))
        let key = SettingsRecordKey(kind: .ssh, id: "default")
        let envelope = SettingsEnvelope(
            key: key, version: .next(after: nil, writerID: UUID()), payload: .ssh(value))
        #expect(!envelope.isValid)
        #expect(throws: SettingsSyncPersistenceError.self) {
            try fixture.store.applyRemote([envelope])
        }
        #expect(try fixture.store.loadSSH() == SSHPreferences())
    }

    @Test
    func remoteSnapshotsWithoutSSHDoNotResetTheCurrentLimit() throws {
        let fixture = try Fixture(maxSessions: 60)
        defer { fixture.cleanUp() }
        let payload = SettingsRecordPayload.webSearch(.init(isEnabled: false))
        let result = try fixture.store.applyRemote([
            SettingsEnvelope(
                key: payload.key, version: .next(after: nil, writerID: UUID()), payload: payload
            )
        ])
        #expect(result.snapshot.ssh == SSHPreferences(maxSessions: 60))
        #expect(try fixture.store.loadSSH() == SSHPreferences(maxSessions: 60))
    }

    @Test
    func version22StoreMigratesAndSeedsSSHPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Store.sqlite")
        let oldSchema = Schema(versionedSchema: TermindSchemaV22.self)
        var old: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none))
        old!.mainContext.insert(PersistentHostGroup(HostGroup(name: "Before SSH preferences")))
        try old!.mainContext.save()
        old = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let domain = "SSHMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(17, forKey: SettingsKey.sshMaxSessions)
        let store = SettingsSyncPersistence(context: migrated.mainContext, defaults: defaults)
        try store.prepare()
        #expect(try store.loadSSH() == SSHPreferences(maxSessions: 17))
        #expect(try migrated.mainContext.fetchCount(FetchDescriptor<PersistentSSHPreferences>()) == 1)
    }

    private struct Fixture {
        let domain = "SSHSettingsSync.\(UUID())"
        let container: ModelContainer
        let defaults: UserDefaults
        let store: SettingsSyncPersistence

        init(maxSessions: Int? = nil) throws {
            container = try TermindPersistence.makeContainer(inMemory: true)
            defaults = try #require(UserDefaults(suiteName: domain))
            if let maxSessions { defaults.set(maxSessions, forKey: SettingsKey.sshMaxSessions) }
            store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
            try store.prepare()
        }

        func cleanUp() { defaults.removePersistentDomain(forName: domain) }
    }
}

@MainActor
private final class TestSSHPreferencesPersistence: SSHPreferencesPersisting {
    var value = SSHPreferences()
    var fail = false

    func loadSSH() throws -> SSHPreferences { value }
    func saveSSH(_ value: SSHPreferences) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        self.value = value
    }
}
