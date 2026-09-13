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
        #expect(TermindMigrationPlan.schemas.count == 15)
    }
}
