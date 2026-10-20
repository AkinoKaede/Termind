// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct WorkspacePreferencesTests {
    @Test
    func namesUseTheBaseWhenFreeAndAppendAfterTheMaximumWhenOccupied() {
        #expect(
            WorkspaceNameAllocator.nextName(
                prefix: "Server", occupiedNames: ["Server (3)"], automaticallyRenames: true)
                == "Server")
        #expect(
            WorkspaceNameAllocator.nextName(
                prefix: "Server", occupiedNames: ["Server", "Server (1)", "Server (3)"],
                automaticallyRenames: true)
                == "Server (4)")
        #expect(
            WorkspaceNameAllocator.nextName(
                prefix: "Server", occupiedNames: ["Server", "Server 9", "Server (4) extra"],
                automaticallyRenames: true)
                == "Server (1)")
        #expect(
            WorkspaceNameAllocator.nextName(
                prefix: "Server", occupiedNames: ["Server", "Server (8)"], automaticallyRenames: false)
                == "Server")

        #expect(
            WorkspaceNameAllocator.nextName(
                prefix: "Server", occupiedNames: ["Server", "Server 1"], automaticallyRenames: true)
                == "Server (1)")
        #expect(
            WorkspaceNameAllocator.nextName(
                prefix: "Server 1", occupiedNames: ["Server", "Server 1", "Server (1)"],
                automaticallyRenames: true)
                == "Server 1 (1)")
    }

    @Test
    func numericAndPatternCharactersInTheHostNameRemainPartOfTheLiteralPrefix() {
        for prefix in ["Server 2", "api.example", "node[1]", #"host\path"#] {
            #expect(
                WorkspaceNameAllocator.nextName(
                    prefix: prefix,
                    occupiedNames: [prefix, "\(prefix) (1)", "\(prefix) (3)"],
                    automaticallyRenames: true)
                    == "\(prefix) (4)")
        }
    }

    @Test
    func workspaceSettingDefaultsOnAndFailedSavesDoNotChangeRuntimeState() {
        let persistence = FailingWorkspacePreferencesPersistence()
        let model = WorkspaceSettingsModel(persistence: persistence)
        #expect(model.preferences.automaticallyRenamesWorkspaces)

        persistence.fail = true
        #expect(!model.setAutomaticRenaming(false))
        #expect(model.preferences.automaticallyRenamesWorkspaces)
        #expect(model.storageError != nil)

        model.applyRemoteSnapshot(.init(automaticallyRenamesWorkspaces: false))
        #expect(!model.preferences.automaticallyRenamesWorkspaces)
        #expect(model.storageError == nil)
    }

    @Test
    func workspaceSettingsUseAnOldClientSafeRecordTypeAndApplyWithoutEcho() throws {
        let source = try Fixture()
        let destination = try Fixture()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let value = WorkspacePreferences(automaticallyRenamesWorkspaces: false)
        try source.store.saveWorkspacePreferences(value)
        let key = SettingsRecordKey(kind: .workspace, id: "default")
        let outgoing = try #require(try source.store.journal.envelope(for: key))
        let recordID = CKRecord.ID(
            recordName: key.recordName,
            zoneID: .init(zoneName: SettingsSyncCoordinator.zoneName))
        let record = try SettingsSyncCoordinator.makeRecord(.init(envelope: outgoing), recordID: recordID)
        #expect(record.recordType == SettingsSyncCoordinator.workspaceRecordType)
        #expect(record.recordType != SettingsSyncCoordinator.recordType)

        var callbacks = 0
        destination.store.didRecordChanges = { _ in callbacks += 1 }
        let result = try destination.store.applyRemote([SettingsSyncCoordinator.envelope(from: record)])
        #expect(result.snapshot.workspace == value)
        #expect(try destination.store.loadWorkspacePreferences() == value)
        #expect(callbacks == 0)
    }
}

@MainActor
private final class FailingWorkspacePreferencesPersistence: WorkspacePreferencesPersisting {
    var value = WorkspacePreferences()
    var fail = false

    func loadWorkspacePreferences() throws -> WorkspacePreferences { value }

    func saveWorkspacePreferences(_ value: WorkspacePreferences) throws {
        if fail { throw CocoaError(.fileWriteUnknown) }
        self.value = value
    }
}

@MainActor
private struct Fixture {
    let domain: String
    let defaults: UserDefaults
    let container: ModelContainer
    let store: SettingsSyncPersistence

    init() throws {
        domain = "WorkspacePreferencesTests.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        container = try TermindPersistence.makeContainer(inMemory: true)
        store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
    }
}
