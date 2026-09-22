import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

private final class FixtureBundle: NSObject {}

@Suite @MainActor
struct PersistenceCompatibilityTests {
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
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(28, 0, 0) })
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(29, 0, 0) })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV30.versionIdentifier })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV31.versionIdentifier })
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(32, 0, 0) })
        #expect(!TermindMigrationPlan.schemas.contains { $0.versionIdentifier == Schema.Version(33, 0, 0) })
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV34.versionIdentifier })
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
    func version27StoreMigratesDirectlyToVersion30Shape() throws {
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
