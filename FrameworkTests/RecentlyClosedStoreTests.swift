import Foundation
import TermindInfrastructure
import Testing

@Suite @MainActor
struct RecentlyClosedStoreTests {
    private struct Entry: Codable, Identifiable {
        let id: UUID
        let title: String
    }

    @Test func recordsAcrossLaunchesShareOneBoundedListAndConsumedRecordsDoNotReturn() throws {
        let name = "RecentlyClosed.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
        let entries = (0..<17).map { Entry(id: UUID(), title: "\($0)") }
        for entry in entries { first.record(entry) }
        #expect(first.entries.count == 15)
        let restarted = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
        #expect(restarted.entries.map(\.id) == entries.suffix(15).reversed().map(\.id))
        restarted.remove(entries[16].id)
        let current = Entry(id: UUID(), title: "Current")
        restarted.record(current)
        #expect(restarted.entries.first?.id == current.id)
        let nextLaunch = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
        #expect(nextLaunch.entries.first?.id == current.id)
        #expect(!nextLaunch.entries.contains { $0.id == entries[16].id })
    }

    @Test func unreadableStoreIsNotOverwritten() throws {
        let name = "RecentlyClosed.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let invalid = Data("invalid".utf8)
        defaults.set(invalid, forKey: "records")
        let store = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
        store.record(Entry(id: UUID(), title: "New"))
        #expect(store.storageError != nil)
        #expect(defaults.data(forKey: "records") == invalid)
    }

    @Test func launchesWithoutClosedRecordsPreserveTheLastSavedRecords() throws {
        let name = "RecentlyClosed.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = Entry(id: UUID(), title: "Server")
        RecentlyClosedStore<Entry>(defaults: defaults, key: "records").record(entry)
        let saved = try #require(defaults.data(forKey: "records"))

        for _ in 0..<3 {
            let launch = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
            #expect(launch.entries.map(\.id) == [entry.id])
        }
        #expect(defaults.data(forKey: "records") == saved)

        let next = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
        next.remove(entry.id)
        let afterReopen = RecentlyClosedStore<Entry>(defaults: defaults, key: "records")
        #expect(afterReopen.entries.isEmpty)
    }
}
