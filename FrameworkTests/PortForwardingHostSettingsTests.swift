import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct PortForwardingHostSettingsTests {
    @Test
    func defaultsClampAndDecodeOldHosts() throws {
        #expect(Host(name: "Default", host: "default.invalid").portForwardingMaxConnections == 1)
        #expect(
            Host(name: "Low", host: "low.invalid", portForwardingMaxConnections: 0)
                .portForwardingMaxConnections == 1)
        #expect(
            Host(name: "High", host: "high.invalid", portForwardingMaxConnections: 65)
                .portForwardingMaxConnections == 64)

        let old = Data(
            """
            {
              "id":"11111111-1111-1111-1111-111111111111", "name":"Old", "host":"old.invalid", "port":22,
              "sftpSessionInitialPath":"", "tags":[], "colorTag":"none", "sortIndex":0
            }
            """.utf8)
        #expect(try JSONDecoder().decode(Host.self, from: old).portForwardingMaxConnections == 1)
    }

    @Test
    func version23StoreMigratesHostLimitToOne() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Store.sqlite")
        let oldSchema = Schema(versionedSchema: TermindSchemaV23.self)
        var old: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none))
        old!.mainContext.insert(
            TermindSchemaV22HostModels.PersistentHost(Host(name: "Before pool", host: "pool.invalid")))
        try old!.mainContext.save()
        old = nil

        let migrated = try TermindPersistence.makeContainer(url: url)
        let hosts = try migrated.mainContext.fetch(FetchDescriptor<PersistentHost>()).map(\.value)
        #expect(hosts.count == 1)
        #expect(hosts.first?.portForwardingMaxConnections == 1)
    }

    @Test
    func currentStoreRoundTripsMaximum() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let host = Host(name: "Pool", host: "pool.invalid", portForwardingMaxConnections: 64)
        container.mainContext.insert(PersistentHost(host))
        try container.mainContext.save()
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value == host)
    }
}
