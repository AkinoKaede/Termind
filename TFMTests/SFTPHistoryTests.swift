import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct SFTPHistoryTests {
    @Test
    func recordsOnlyPathsAndRefreshesDuplicateRecency() {
        let hostID = UUID()
        let model = SFTPHistoryModel()

        model.record(
            kind: .directory, path: "/srv/../srv/app", for: hostID,
            at: Date(timeIntervalSince1970: 1)
        )
        model.record(
            kind: .file, path: "/srv/app/config.json", for: hostID,
            at: Date(timeIntervalSince1970: 2)
        )
        model.record(
            kind: .directory, path: "/srv/app", for: hostID,
            at: Date(timeIntervalSince1970: 3)
        )

        let entries = model.entries(for: hostID)
        #expect(entries.count == 2)
        #expect(entries.map(\.kind) == [.directory, .file])
        #expect(entries.map(\.path) == ["/srv/app", "/srv/app/config.json"])
    }

    @Test
    func swiftDataRepositoryPersistsAndClearsPerHost() throws {
        let configuration = localModelConfiguration(
            "SFTPHistoryTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let hostID = UUID()
        let otherHostID = UUID()
        let model = SFTPHistoryModel(modelContext: container.mainContext)

        model.record(kind: .directory, path: "/var/log", for: hostID)
        model.record(kind: .file, path: "/tmp/a.txt", for: otherHostID)
        #expect(model.storageError == nil)
        let rowCount = try container.mainContext.fetch(FetchDescriptor<PersistentSFTPHistoryEntry>()).count
        #expect(rowCount == 2)
        #expect(model.entries(for: hostID).map(\.path) == ["/var/log"])

        model.clear(for: hostID)
        #expect(model.entries(for: hostID).isEmpty)
        #expect(model.entries(for: otherHostID).map(\.path) == ["/tmp/a.txt"])
    }
}
