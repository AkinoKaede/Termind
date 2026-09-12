import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite
@MainActor
struct SFTPHistoryTests {
    @Test func memoryStoreNormalizesDeduplicatesSearchesAndScopesByHost() throws {
        let firstHost = UUID()
        let secondHost = UUID()
        let model = SFTPHistoryModel()

        model.record(
            kind: .directory, path: "/srv/../srv/app", for: firstHost,
            at: Date(timeIntervalSince1970: 1)
        )
        model.record(
            kind: .file, path: "/srv/app/config.json", for: firstHost,
            at: Date(timeIntervalSince1970: 2)
        )
        model.record(
            kind: .directory, path: "/srv/app", for: firstHost,
            at: Date(timeIntervalSince1970: 3)
        )
        model.record(
            kind: .directory, path: "/var/log", for: secondHost,
            at: Date(timeIntervalSince1970: 4)
        )

        #expect(model.entries(for: firstHost).map(\.kind) == [.directory, .file])
        #expect(model.entries(for: firstHost).map(\.path) == ["/srv/app", "/srv/app/config.json"])
        #expect(model.entries(for: firstHost, matching: "CONFIG").map(\.kind) == [.file])
        #expect(model.entries(for: secondHost).map(\.path) == ["/var/log"])
    }

    @Test func memoryStoreTrimsDeletesAndClearsPerHost() throws {
        let hostID = UUID()
        let otherHostID = UUID()
        let model = SFTPHistoryModel()

        for index in 0...SFTPHistoryModel.perHostLimit {
            model.record(
                kind: .directory, path: "/directory-\(index)", for: hostID,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        model.record(kind: .file, path: "/keep.txt", for: otherHostID)

        let entries = model.entries(for: hostID)
        #expect(entries.count == SFTPHistoryModel.perHostLimit)
        #expect(entries.first?.path == "/directory-1000")
        #expect(entries.last?.path == "/directory-1")

        let removed = try #require(entries.first)
        model.delete(removed.id)
        #expect(!model.entries(for: hostID).contains { $0.id == removed.id })
        model.clear(for: hostID)
        #expect(model.entries(for: hostID).isEmpty)
        #expect(model.entries(for: otherHostID).map(\.path) == ["/keep.txt"])
    }

    @Test func swiftDataRepositoryPersistsAndClearsPerHost() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let hostID = UUID()
        let otherHostID = UUID()
        let model = SFTPHistoryModel(
            repository: SwiftDataSFTPHistoryRepository(context: ModelContext(container))
        )

        model.record(kind: .directory, path: "/var/log", for: hostID)
        model.record(kind: .file, path: "/tmp/a.txt", for: otherHostID)
        #expect(model.storageError == nil)

        let reloaded = SFTPHistoryModel(
            repository: SwiftDataSFTPHistoryRepository(context: ModelContext(container))
        )
        #expect(reloaded.entries(for: hostID).map(\.path) == ["/var/log"])
        #expect(reloaded.entries(for: otherHostID).map(\.path) == ["/tmp/a.txt"])

        reloaded.clear(for: hostID)
        #expect(reloaded.entries(for: hostID).isEmpty)
        #expect(reloaded.entries(for: otherHostID).map(\.path) == ["/tmp/a.txt"])
    }
}
