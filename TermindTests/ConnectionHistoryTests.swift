import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct ConnectionHistoryTests {
    @Test
    func schemaV5MigratesWithAnEmptyConnectionTimeline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionHistoryMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: TermindSchemaV5.self)

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration(
                    "ConnectionHistoryMigration", schema: legacySchema, url: storeURL
                )
            ]
        )
        let legacyHost = TermindSchemaV7HostModels.PersistentHost(
            Host(name: "Existing", host: "existing.example")
        )
        legacyHost.lastUsedAt = Date(timeIntervalSince1970: 123)
        legacyContainer?.mainContext.insert(legacyHost)
        try legacyContainer?.mainContext.save()
        legacyContainer = nil

        let migrated = try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [
                localModelConfiguration(
                    "ConnectionHistoryMigration",
                    schema: HostPersistence.schema, url: storeURL
                )
            ]
        )

        let migratedHosts = try migrated.mainContext.fetch(FetchDescriptor<PersistentHost>())
        #expect(migratedHosts.count == 1)
        #expect(migratedHosts.first?.lastUsedAt == nil)
        #expect(try migrated.mainContext.fetch(
            FetchDescriptor<PersistentConnectionHistoryEntry>()
        ).isEmpty)
    }

    @Test
    func repeatedHostsRemainDistinctAndSortedByAttemptTime() {
        let hostID = UUID()
        let model = ConnectionHistoryModel()

        model.record(kind: .ssh, for: hostID, at: Date(timeIntervalSince1970: 1))
        model.record(kind: .sftp, for: hostID, at: Date(timeIntervalSince1970: 3))
        model.record(kind: .ssh, for: hostID, at: Date(timeIntervalSince1970: 2))

        let entries = model.entries()
        #expect(entries.count == 3)
        #expect(entries.map(\.kind) == [.sftp, .ssh, .ssh])
        #expect(entries.map(\.connectedAt) == [
            Date(timeIntervalSince1970: 3),
            Date(timeIntervalSince1970: 2),
            Date(timeIntervalSince1970: 1),
        ])
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test
    func globalLimitKeepsTheNewestAttempts() {
        let model = ConnectionHistoryModel()
        for index in 0...ConnectionHistoryModel.limit {
            model.record(
                kind: .ssh, for: UUID(),
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let entries = model.entries()
        #expect(entries.count == ConnectionHistoryModel.limit)
        #expect(entries.first?.connectedAt == Date(
            timeIntervalSince1970: TimeInterval(ConnectionHistoryModel.limit)
        ))
        #expect(entries.last?.connectedAt == Date(timeIntervalSince1970: 1))
    }

    @Test
    func swiftDataRepositoryPersistsDeletesAndClears() throws {
        let configuration = localModelConfiguration(
            "ConnectionHistoryTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let hostID = UUID()
        let otherHostID = UUID()
        let model = ConnectionHistoryModel(modelContext: container.mainContext)

        let first = try #require(model.record(kind: .ssh, for: hostID))
        model.record(kind: .sftp, for: hostID)
        model.record(kind: .ssh, for: otherHostID)
        #expect(model.storageError == nil)
        #expect(try container.mainContext.fetch(
            FetchDescriptor<PersistentConnectionHistoryEntry>()
        ).count == 3)

        model.delete(first.id)
        #expect(model.entries(for: hostID).count == 1)
        model.clear(for: hostID)
        #expect(model.entries(for: hostID).isEmpty)
        #expect(model.entries(for: otherHostID).count == 1)
        model.clearAll()
        #expect(model.entries().isEmpty)
    }

    @Test
    func openingSavedHostsRecordsKindsAndDrivesRecents() {
        let first = Host(name: "First", host: "first.example")
        let second = Host(name: "Second", host: "second.example")
        let history = ConnectionHistoryModel()
        let app = AppModel(
            hosts: HostLibraryModel(hosts: [first, second]),
            connectionHistory: history
        )
        let window = WindowModel()

        app.open(first, as: .sshSession, in: window)
        app.open(second, as: .sftpSession, in: window)
        app.open(first, as: .sftpSession, in: window)

        #expect(history.entries().map(\.hostID) == [first.id, second.id, first.id])
        #expect(history.entries().map(\.kind) == [.sftp, .sftp, .ssh])
        #expect(app.recentHosts().map(\.id) == [first.id, second.id])
        #expect(app.lastConnectedAt(for: first.id) != nil)
    }

    @Test
    func clearAllHistoryForHostKeepsHostAndOtherHostHistory() {
        let host = Host(name: "Host", host: "host.example")
        let other = Host(name: "Other", host: "other.example")
        let connections = ConnectionHistoryModel(entries: [
            ConnectionHistoryEntry(hostID: host.id, kind: .ssh),
            ConnectionHistoryEntry(hostID: other.id, kind: .ssh),
        ])
        let commands = CommandHistoryModel(entries: [
            CommandHistoryEntry(hostID: host.id, command: "uptime"),
        ])
        let files = SFTPHistoryModel(entries: [
            SFTPHistoryEntry(hostID: host.id, kind: .directory, path: "/srv"),
        ])
        let app = AppModel(
            hosts: HostLibraryModel(hosts: [host, other]),
            commandHistory: commands, sftpHistory: files,
            connectionHistory: connections
        )

        app.clearAllHistory(for: [host.id])

        #expect(app.hostLibrary.host(host.id) != nil)
        #expect(connections.entries(for: host.id).isEmpty)
        #expect(commands.entries(for: host.id).isEmpty)
        #expect(files.entries(for: host.id).isEmpty)
        #expect(connections.entries(for: other.id).count == 1)
        #expect(app.recentHosts().map(\.id) == [other.id])
    }
}
