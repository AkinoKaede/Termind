import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct PersistenceCompatibilityTests {
    @Test func version35DropsRetiredImporterTableAndPreservesNativeHistoryOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.store")
        let device = DeviceRecord(id: UUID(), displayName: "Saved Mac")
        try writeVersion35Store(to: url, device: device)
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let persistence = HistorySyncPersistence(context: container.mainContext)
            try persistence.prepare()
            #expect(!container.schema.entities.contains { $0.name == "PersistentHistoryImportState" })
            #expect(try container.mainContext.fetch(FetchDescriptor<PersistentDeviceRecord>()).map(\.value) == [device])
            let entry = try #require(try persistence.journal.envelope(for: .init(kind: .device, id: device.id)))
            #expect(entry.payload == .device(device))
            #expect(
                try HistorySyncJournal(context: container.mainContext, kind: .connectionHistory).state()
                    .boundUserRecordName == "existing-account")
            #expect(
                try HistorySyncJournal(context: container.mainContext, kind: .device).state()
                    .boundUserRecordName == "existing-account")
        }
    }

    private func writeVersion35Store(to url: URL, device: DeviceRecord) throws {
        let schema = Schema(versionedSchema: TermindSchemaV35.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(PersistentHistoryImportState(scopeKey: "retired-import"))
        let state = PersistentHistorySyncState()
        state.boundUserRecordName = "existing-account"
        state.bootstrapCompleted = true
        container.mainContext.insert(state)
        let payload = HistoryRecordPayload.device(device)
        container.mainContext.insert(
            try PersistentHistorySyncEntry(
                envelope: HistoryEnvelope(
                    key: payload.key, version: .baseline(writerID: state.installationID), payload: payload),
                needsUpload: false))
        container.mainContext.insert(PersistentDeviceRecord(device))
        try container.mainContext.save()
    }

    @Test(arguments: [31, 34])
    func oldStoresReopenWithoutImportingRetiredHistoryJournal(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.store")
        let installationID = UUID()
        let eventID = UUID()
        try writeLegacyHistoryStore(to: url, version: version, installationID: installationID, eventID: eventID)
        try verifyMigratedHistoryStore(at: url, installationID: installationID, eventID: eventID)
        try verifyMigratedHistoryStore(at: url, installationID: installationID, eventID: eventID)
    }

    private func writeLegacyHistoryStore(to url: URL, version: Int, installationID: UUID, eventID: UUID) throws {
        let schema =
            version == 31
            ? Schema(versionedSchema: TermindSchemaV31.self) : Schema(versionedSchema: TermindSchemaV34.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        let state = PersistentVaultSyncState()
        state.installationID = installationID
        state.boundUserRecordName = "old-account"
        state.bootstrapCompleted = true
        container.mainContext.insert(state)
        let envelope = VaultEnvelope(
            key: .init(kind: .connectionHistory, id: eventID),
            version: .baseline(writerID: installationID), isDeleted: true)
        let row = try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true)
        row.systemFieldsData = Data([4, 5, 6])
        container.mainContext.insert(row)
        try container.mainContext.save()
    }

    private func verifyMigratedHistoryStore(at url: URL, installationID: UUID, eventID: UUID) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let persistence = HistorySyncPersistence(context: container.mainContext)
        try persistence.prepare()
        let state = try persistence.journal.state()
        #expect(state.installationID != installationID)
        #expect(state.boundUserRecordName == nil)
        #expect(try persistence.journal.envelope(for: .init(kind: .connectionHistory, id: eventID)) == nil)
        #expect(
            try VaultSyncJournal(context: container.mainContext).pendingEnvelopes().allSatisfy {
                $0.key.kind.isConfiguration
            })
    }

    @Test
    func credentialStorageNamesAndDefaultsRemainCompatible() {
        #expect(KeyStorage.thisDevice.rawValue == "thisDevice")
        #expect(PasswordStorage.thisDevice.rawValue == "thisDevice")
        #expect(KeyStorage.iCloud.rawValue == "iCloud")
        #expect(PasswordStorage.iCloud.rawValue == "iCloud")
        #expect(KeyStorage(rawValue: "local" + "Keychain") == nil)
        #expect(Identity(name: "", username: "").passwordStorage == .iCloud)
        #expect(SSHKeyRef(label: "").storage == .iCloud)
    }

    @Test
    func fileStoreReopensWithSharedModels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        try writeGroup(to: url)
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.name) == ["Saved group"])
    }

    private func writeGroup(to url: URL) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        container.mainContext.insert(PersistentHostGroup(HostGroup(name: "Saved group")))
        try container.mainContext.save()
    }

    @Test
    func memoryContainersUseTheFullSchemaAndRemainIndependent() throws {
        let first = try TermindPersistence.makeContainer(inMemory: true)
        let second = try TermindPersistence.makeContainer(inMemory: true)
        first.mainContext.insert(PersistentHostGroup(HostGroup(name: "Temporary")))
        try first.mainContext.save()
        #expect(try second.mainContext.fetchCount(FetchDescriptor<PersistentHostGroup>()) == 0)
        #expect(Set(first.schema.entities.map(\.name)) == Set(TermindPersistence.schema.entities.map(\.name)))
    }

    @Test
    func version31StoreMigratesDirectlyToVersion34Shape() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV31.self)
        let oldConfiguration = ModelConfiguration(
            "Termind", schema: oldSchema, url: url, cloudKitDatabase: .none
        )
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration]
        )
        let oldHost = TermindSchemaV29HostModels.PersistentHost(
            Host(name: "Before V34", host: "server.invalid"))
        oldHost.lastUsedAt = Date(timeIntervalSince1970: 100)
        let oldHistory = TermindSchemaV31ConnectionHistoryModels.PersistentConnectionHistoryEntry(
            ConnectionHistoryEntry(
                hostID: oldHost.id, kind: .ssh,
                connectedAt: Date(timeIntervalSince1970: 90)))
        let identity = Identity(
            name: "Before V34", username: "deploy", credentialRef: "termind.password.deploy",
            colorTag: .purple)
        let oldIdentity = TermindSchemaV25IdentityModels.PersistentIdentity(identity)
        oldIdentity.lastUsedAt = Date(timeIntervalSince1970: 900)
        let modifiedAt = Date(timeIntervalSince1970: 500)
        let recordKey = VaultRecordKey(kind: .identity, id: identity.id)
        oldContainer?.mainContext.insert(oldHost)
        oldContainer?.mainContext.insert(oldHistory)
        oldContainer?.mainContext.insert(oldIdentity)
        oldContainer?.mainContext.insert(PersistentHostGroup(HostGroup(name: "Before V34")))
        oldContainer?.mainContext.insert(
            try PersistentVaultSyncEntry(
                envelope: VaultEnvelope(
                    key: recordKey,
                    version: VaultVersion(modifiedAt: modifiedAt, counter: 0, writerID: UUID()),
                    payload: .identity(identity)),
                needsUpload: false))
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let host = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value)
        let history = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).first?.value)
        let state = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentVaultSyncState>()).first)
        let sourceDevice = try #require(
            migrated.mainContext.fetch(
                FetchDescriptor<PersistentDeviceRecord>()
            ).first?.value)
        let savedIdentity = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentIdentity>()).first?.value)
        let dates = try HostPersistence(context: migrated.mainContext).modificationDates()
        let defaults = try #require(UserDefaults(suiteName: "PersistenceV34.\(UUID())"))
        let settings = SettingsSyncPersistence(context: migrated.mainContext, defaults: defaults)
        try settings.prepare()
        let workspaceKey = SettingsRecordKey(kind: .workspace, id: "default")

        #expect(host.name == "Before V34")
        #expect(history.hostID == host.id)
        #expect(history.sourceDeviceID == state.installationID)
        #expect(sourceDevice.id == state.installationID)
        #expect(sourceDevice.displayName == ProcessInfo.processInfo.hostName)
        #expect(history.endedAt == nil)
        #expect(savedIdentity.name == identity.name)
        #expect(savedIdentity.username == identity.username)
        #expect(savedIdentity.credentialRef == identity.credentialRef)
        #expect(savedIdentity.colorTag == identity.colorTag)
        #expect(dates[recordKey] == modifiedAt)
        #expect(try settings.loadWorkspacePreferences() == WorkspacePreferences())
        #expect(
            try settings.journal.envelope(for: workspaceKey)?.payload == .workspace(WorkspacePreferences()))
    }

    @Test
    func version30StoreMigratesToVersion31WithoutLosingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV30.self)
        let oldConfiguration = ModelConfiguration(
            "Termind", schema: oldSchema, url: url, cloudKitDatabase: .none
        )
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration]
        )
        oldContainer?.mainContext.insert(
            TermindSchemaV29HostModels.PersistentHost(
                Host(name: "TestFlight host", host: "server.invalid", telnetEnabled: true)
            )
        )
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let host = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value
        )
        #expect(host.name == "TestFlight host")
        #expect(host.telnetEnabled)
        #expect(try migrated.mainContext.fetchCount(FetchDescriptor<PersistentCloudSyncQuarantine>()) == 0)
        #expect(try migrated.mainContext.fetchCount(FetchDescriptor<PersistentCloudSyncRecovery>()) == 0)
    }

    @Test
    func version41StoreMigratesToVersion42WithEmptyCollaborationSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV41.self)
        let oldConfiguration = ModelConfiguration(
            "Termind", schema: oldSchema, url: url, cloudKitDatabase: .none)
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration])
        oldContainer?.mainContext.insert(PersistentHostGroup(HostGroup(name: "Before collaboration")))
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        #expect(
            try migrated.mainContext.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.name)
                == ["Before collaboration"])
        #expect(
            try migrated.mainContext.fetchCount(
                FetchDescriptor<PersistentAgentMessageOrigin>()) == 0)
        #expect(
            try migrated.mainContext.fetchCount(
                FetchDescriptor<PersistentAgentConversationOrigin>()) == 0)
        #expect(
            try migrated.mainContext.fetchCount(
                FetchDescriptor<PersistentAgentDeliveryReceipt>()) == 0)
    }

    @Test
    func version25StoreMigratesWithNoStartupSnippet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV25.self)
        let oldConfiguration = ModelConfiguration(
            "Termind", schema: oldSchema, url: url, cloudKitDatabase: .none
        )
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration]
        )
        oldContainer?.mainContext.insert(
            TermindSchemaV24HostModels.PersistentHost(
                Host(name: "Before startup snippets", host: "server.invalid")
            )
        )
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let host = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value
        )
        #expect(host.name == "Before startup snippets")
        #expect(host.startupSnippetID == nil)
    }

    @Test
    func version26StoreMigratesWithNoEnvironmentVariables() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV26.self)
        let oldConfiguration = ModelConfiguration(
            "Termind", schema: oldSchema, url: url, cloudKitDatabase: .none
        )
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration]
        )
        oldContainer?.mainContext.insert(
            TermindSchemaV26HostModels.PersistentHost(
                Host(name: "Before environment variables", host: "server.invalid")
            )
        )
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let host = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value
        )
        #expect(host.name == "Before environment variables")
        #expect(host.environmentVariables.isEmpty)
    }

    @Test
    func version27StoreMigratesThroughRestoredVersionsWithoutLosingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV27.self)
        let oldConfiguration = ModelConfiguration(
            "Termind", schema: oldSchema, url: url, cloudKitDatabase: .none
        )
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration]
        )
        oldContainer?.mainContext.insert(
            TermindSchemaV27HostModels.PersistentHost(
                Host(name: "Before charset", host: "server.invalid")
            )
        )
        let knownHost = KnownHostEntry(
            hostname: "server.invalid", algorithm: .ed25519,
            fingerprint: "SHA256:known-host"
        )
        let knownHostRecord = TermindSchemaV29KnownHostModels.PersistentKnownHost(knownHost)
        knownHostRecord.isMismatched = true
        oldContainer?.mainContext.insert(knownHostRecord)
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let host = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value
        )
        #expect(host.name == "Before charset")
        #expect(host.charset == .utf8)
        #expect(host.sshEnabled)
        #expect(!host.telnetEnabled)
        let knownHosts = try migrated.mainContext.fetch(FetchDescriptor<PersistentKnownHost>())
        #expect(knownHosts.map(\.value) == [knownHost])
    }

    @Test
    func version16StoreMigratesWithAnEmptyWorkspaceTemplateLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV16.self)
        let oldConfiguration = ModelConfiguration("Termind", schema: oldSchema, url: url, cloudKitDatabase: .none)
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema, configurations: [oldConfiguration])
        oldContainer?.mainContext.insert(PersistentHostGroup(HostGroup(name: "Before templates")))
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)

        #expect(
            try migrated.mainContext.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.name)
                == ["Before templates"]
        )
        #expect(try migrated.mainContext.fetchCount(FetchDescriptor<PersistentWorkspaceTemplate>()) == 0)
    }
}
