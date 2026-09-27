import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

private final class FixtureBundle: NSObject {}

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

    @Test(arguments: [1, 14])
    func originalAppModuleStoresOpenWithoutLosingData(version: Int) throws {
        let source = try #require(
            Bundle(for: FixtureBundle.self).url(forResource: "V\(version)", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        try FileManager.default.copyItem(at: source, to: url)
        let container = try TermindPersistence.makeContainer(url: url)
        let groups = try container.mainContext.fetch(FetchDescriptor<PersistentHostGroup>())
        #expect(groups.map(\.name) == ["Legacy fixture group"])
        #expect(groups.first?.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        if version == 1 {
            let providers = try container.mainContext.fetch(FetchDescriptor<PersistentModelProvider>())
            #expect(providers.map(\.name) == ["Legacy fixture provider"])
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentTerminalPreferences>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentMetricsSyncEntry>()) == 0)
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
    func version28FixtureMigratesAndReopensWithoutLosingData() throws {
        let source = try #require(Bundle(for: FixtureBundle.self).url(forResource: "V28", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        try FileManager.default.copyItem(at: source, to: url)

        try verifyVersion28Store(at: url)
        try verifyVersion28Store(at: url)
    }

    private func verifyVersion28Store(at url: URL) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let context = container.mainContext
        let snapshot = try HostPersistence(context: context).load()
        let host = try #require(snapshot.hosts.first)
        let identity = try #require(snapshot.identities.first)
        let key = try #require(snapshot.keys.first)
        let snippet = try #require(snapshot.snippets.first)
        let installationID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

        #expect(snapshot.hosts.count == 1)
        #expect(host.id == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(host.name == "V28 fixture host")
        #expect(host.host == "legacy.example.invalid")
        #expect(host.sshEnabled)
        #expect(host.sshPort == 2222)
        #expect(host.sshCharset == .gb18030)
        #expect(!host.telnetEnabled)
        #expect(host.telnetPort == 23)
        #expect(host.telnetCharset == .utf8)
        #expect(host.telnetIdentityID == nil)
        #expect(host.sshIdentityID == identity.id)
        #expect(host.groupID == snapshot.groups.first?.id)
        #expect(snapshot.groups.map(\.name) == ["V28 fixture group"])
        #expect(host.tags == ["legacy", "ssh"])
        #expect(host.colorTag == .teal)
        #expect(host.sortIndex == 2.5)
        #expect(host.shellIntegrationMode == .disabled)
        #expect(host.portForwardingMaxConnections == 3)
        #expect(host.sftpChannelInitialPath == "/srv/legacy")
        #expect(
            host.environmentVariables == [
                HostEnvironmentVariable(variable: "LANG", value: "zh_CN.GB18030"),
                HostEnvironmentVariable(variable: "TERM", value: "xterm-256color"),
            ])
        #expect(host.startupSnippetID == snippet.id)
        #expect(snippet.body == "pwd")
        #expect(snippet.targetHostIDs == [host.id])
        #expect(identity.id == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        #expect(identity.username == "deploy")
        #expect(identity.credentialRef == "termind.fixture.password")
        #expect(identity.passwordStorage == .thisDevice)
        #expect(identity.keyID == key.id)
        #expect(identity.notes == "Synthetic fixture")
        #expect(identity.colorTag == .purple)
        #expect(key.id == UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        #expect(key.label == "V28 fixture key")
        #expect(
            snapshot.knownHosts == [
                KnownHostEntry(
                    id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    hostname: "legacy.example.invalid", port: 2222,
                    fingerprint: "SHA256:fixture", addedAt: Date(timeIntervalSince1970: 50))
            ])
        try HistorySyncPersistence(context: context).prepare()
        let history = try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).map(\.value)
        #expect(
            history == [
                ConnectionHistoryEntry(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    hostID: host.id, kind: .ssh, connectedAt: Date(timeIntervalSince1970: 90),
                    sourceDeviceID: installationID)
            ])
        #expect(try context.fetch(FetchDescriptor<PersistentVaultSyncState>()).first?.installationID == installationID)
        #expect(try context.fetch(FetchDescriptor<PersistentDeviceRecord>()).map(\.id) == [installationID])

        let suite = "PersistenceV28.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsSyncPersistence(context: context, defaults: defaults)
        try settings.prepare()
        #expect(try settings.loadWorkspacePreferences() == WorkspacePreferences())
    }

    @Test
    func memoryContainersUseTheFullSchemaAndRemainIndependent() throws {
        let first = try TermindPersistence.makeContainer(inMemory: true)
        let second = try TermindPersistence.makeContainer(inMemory: true)
        first.mainContext.insert(PersistentHostGroup(HostGroup(name: "Temporary")))
        try first.mainContext.save()
        #expect(try second.mainContext.fetchCount(FetchDescriptor<PersistentHostGroup>()) == 0)
        #expect(Set(first.schema.entities.map(\.name)) == Set(TermindPersistence.schema.entities.map(\.name)))
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV21.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV23.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV24.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV25.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV26.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV27.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV28.versionIdentifier })
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(29, 0, 0) })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV30.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV31.versionIdentifier })
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(32, 0, 0) })
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(33, 0, 0) })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV34.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV42.versionIdentifier })
        #expect(TermindSchemaV22.models.contains { $0 == TermindSchemaV22HostModels.PersistentHost.self })
        #expect(!TermindSchemaV22.models.contains { $0 == TermindSchemaV24HostModels.PersistentHost.self })
        #expect(TermindSchemaV25.models.contains { $0 == TermindSchemaV24HostModels.PersistentHost.self })
        #expect(!TermindSchemaV26.models.contains { $0 == TermindSchemaV24HostModels.PersistentHost.self })
        #expect(TermindSchemaV26.models.contains { $0 == TermindSchemaV26HostModels.PersistentHost.self })
        #expect(!TermindSchemaV27.models.contains { $0 == TermindSchemaV26HostModels.PersistentHost.self })
        #expect(TermindSchemaV27.models.contains { $0 == TermindSchemaV27HostModels.PersistentHost.self })
        #expect(!TermindSchemaV30.models.contains { $0 == TermindSchemaV27HostModels.PersistentHost.self })
        #expect(TermindSchemaV30.models.contains { $0 == TermindSchemaV29HostModels.PersistentHost.self })
        #expect(
            !TermindSchemaV30.models.contains { $0 == TermindSchemaV29KnownHostModels.PersistentKnownHost.self })
        #expect(TermindSchemaV30.models.contains { $0 == TermindSchemaV30KnownHostModels.PersistentKnownHost.self })
        #expect(
            TermindSchemaV31.models.contains {
                $0 == TermindSchemaV29HostModels.PersistentHost.self
            })
        #expect(
            TermindSchemaV34.models.contains {
                $0 == TermindSchemaV32HostModels.PersistentHost.self
            })
        #expect(
            !TermindSchemaV34.models.contains {
                $0 == TermindSchemaV29HostModels.PersistentHost.self
            })
        #expect(
            TermindSchemaV34.models.contains {
                $0 == TermindSchemaV33IdentityModels.PersistentIdentity.self
            })
        #expect(
            !TermindSchemaV34.models.contains {
                $0 == TermindSchemaV25IdentityModels.PersistentIdentity.self
            })
        #expect(first.schema.entities.contains { $0.name == "PersistentModelProviderVertexConfiguration" })
        #expect(first.schema.entities.contains { $0.name == "PersistentSSHPreferences" })
        #expect(first.schema.entities.contains { $0.name == "PersistentSFTPPreferences" })
        #expect(first.schema.entities.contains { $0.name == "PersistentWorkspacePreferences" })
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
