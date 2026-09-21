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
        #expect(TermindMigrationPlan.schemas.contains { $0.versionIdentifier == TermindSchemaV28.versionIdentifier })
        #expect(TermindSchemaV22.models.contains { $0 == TermindSchemaV22HostModels.PersistentHost.self })
        #expect(!TermindSchemaV22.models.contains { $0 == TermindSchemaV24HostModels.PersistentHost.self })
        #expect(TermindSchemaV25.models.contains { $0 == TermindSchemaV24HostModels.PersistentHost.self })
        #expect(!TermindSchemaV26.models.contains { $0 == TermindSchemaV24HostModels.PersistentHost.self })
        #expect(TermindSchemaV26.models.contains { $0 == TermindSchemaV26HostModels.PersistentHost.self })
        #expect(!TermindSchemaV27.models.contains { $0 == TermindSchemaV26HostModels.PersistentHost.self })
        #expect(TermindSchemaV27.models.contains { $0 == TermindSchemaV27HostModels.PersistentHost.self })
        #expect(!TermindSchemaV28.models.contains { $0 == TermindSchemaV27HostModels.PersistentHost.self })
        #expect(TermindSchemaV28.models.contains { $0 == TermindSchemaV28HostModels.PersistentHost.self })
        #expect(first.schema.entities.contains { $0.name == "PersistentModelProviderVertexConfiguration" })
        #expect(first.schema.entities.contains { $0.name == "PersistentSSHPreferences" })
        #expect(first.schema.entities.contains { $0.name == "PersistentSFTPPreferences" })
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
    func version27StoreMigratesWithUTF8Charset() throws {
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
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let host = try #require(
            migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value
        )
        #expect(host.name == "Before charset")
        #expect(host.charset == .utf8)
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
