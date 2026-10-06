import Foundation
import Observation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct HistoryRenderingSnapshotTests {
    @Test func failedClearKeepsLaunchRecordsReadable() throws {
        let repository = HistoryRepository()
        let model = ConnectionHistoryModel(repository: repository)
        let entry = try #require(model.record(kind: .ssh, for: UUID()))
        repository.failsClear = true
        model.clearAll()
        #expect(model.entries().map(\.id) == [entry.id])
        #expect(model.currentLaunchEntryIDs.contains(entry.id))
        #expect(model.storageError != nil)
        repository.failsClear = false
        model.clearAll()
        #expect(model.entries().isEmpty && model.currentLaunchEntryIDs.isEmpty)
        #expect(model.storageError == nil)
    }

    @Test func failedInitialTrimDoesNotHideReadableHistory() throws {
        let repository = HistoryRepository()
        let entry = ConnectionHistoryEntry(hostID: UUID(), kind: .ssh)
        try repository.insert(entry, limit: 10)
        repository.failsTrim = true

        let model = ConnectionHistoryModel(repository: repository)

        #expect(model.entries().map(\.id) == [entry.id])
        #expect(model.storageError != nil)
        model.reload()
        #expect(model.entries().map(\.id) == [entry.id])
        #expect(model.storageError == nil)
    }

    @Test func failedInitialRegistrationDoesNotHideReadableDeviceNames() throws {
        let repository = DeviceRepository()
        let remote = DeviceRecord(id: UUID(), displayName: "Remote")
        try repository.upsert(remote)
        repository.failsWrites = true

        let model = DeviceDirectoryModel(repository: repository, currentDeviceName: "Local")

        #expect(model.name(for: remote.id) == "Remote")
        #expect(model.name(for: model.currentDeviceID) == "Local")
        #expect(model.storageError != nil)
        model.reload()
        #expect(model.name(for: remote.id) == "Remote")
        #expect(model.storageError == nil)
    }

    @Test(arguments: [false, true])
    func historyReadsDoNotFetchOrPublishDuringRendering(fails: Bool) {
        let repository = HistoryRepository()
        repository.fails = fails
        let model = ConnectionHistoryModel(repository: repository)
        let hostID = UUID()
        let reads = repository.reads
        withObservationTracking {
            _ = model.storageError
            _ = model.entries()
        } onChange: {
            Issue.record("Reading history must not publish observable changes")
        }

        for _ in 0..<2 {
            _ = model.entries()
            _ = model.entries(for: hostID)
            _ = model.mostRecentDate(for: hostID)
            _ = model.localEntries()
        }
        #expect(repository.reads == reads)
        #expect((model.storageError != nil) == fails)
    }

    @Test func historyReloadPublishesCommittedRowsAndRecoversFromReadFailure() throws {
        let repository = HistoryRepository()
        let model = ConnectionHistoryModel(repository: repository)
        let entry = ConnectionHistoryEntry(hostID: UUID(), kind: .ssh)
        try repository.insert(entry, limit: 10)
        model.reload()
        #expect(model.entries().map(\.id) == [entry.id])

        repository.fails = true
        model.reload()
        let failedReads = repository.reads
        #expect(model.entries().isEmpty)
        #expect(model.storageError != nil)
        #expect(repository.reads == failedReads)

        repository.fails = false
        model.reload()
        #expect(model.mostRecentDate(for: entry.hostID) == entry.connectedAt)
        #expect(model.storageError == nil)
        model.delete(entry.id)
        #expect(model.entries().isEmpty)
    }

    @Test(arguments: [false, true])
    func deviceReadsDoNotFetchOrPublishDuringRendering(fails: Bool) {
        let repository = DeviceRepository()
        repository.fails = fails
        let model = DeviceDirectoryModel(repository: repository, currentDeviceName: "Local")
        let reads = repository.reads
        withObservationTracking {
            _ = model.storageError
            _ = model.devices()
        } onChange: {
            Issue.record("Reading device names must not publish observable changes")
        }

        for _ in 0..<2 {
            _ = model.devices()
            #expect(model.name(for: model.currentDeviceID) == "Local")
            #expect(model.name(for: UUID()) == nil)
        }
        #expect(repository.reads == reads)
        #expect((model.storageError != nil) == fails)
    }

    @Test func deviceReloadPublishesCommittedNamesAndRecoversFromReadFailure() throws {
        let repository = DeviceRepository()
        let model = DeviceDirectoryModel(repository: repository, currentDeviceName: "Local")
        let remote = DeviceRecord(id: UUID(), displayName: "Remote")
        try repository.upsert(remote)
        model.reload()
        #expect(model.name(for: remote.id) == "Remote")

        repository.fails = true
        model.reload()
        let failedReads = repository.reads
        #expect(model.devices().isEmpty)
        #expect(model.storageError != nil)
        #expect(repository.reads == failedReads)

        repository.fails = false
        model.reload()
        #expect(model.name(for: remote.id) == "Remote")
        #expect(model.storageError == nil)
        model.updateCurrentDeviceName("Renamed")
        #expect(model.name(for: model.currentDeviceID) == "Renamed")
    }

    private enum ReadFailure: Error { case unavailable }

    private final class HistoryRepository: ConnectionHistoryRepository {
        let storage = InMemoryConnectionHistoryRepository()
        var reads = 0
        var fails = false
        var failsTrim = false
        var failsClear = false

        func entries() throws -> [ConnectionHistoryEntry] {
            reads += 1
            if fails { throw ReadFailure.unavailable }
            return try storage.entries()
        }
        func trim(to limit: Int) throws {
            if failsTrim { throw ReadFailure.unavailable }
            try storage.trim(to: limit)
        }
        func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws { try storage.insert(entry, limit: limit) }
        func end(_ id: UUID, at date: Date) throws { try storage.end(id, at: date) }
        func delete(_ id: UUID) throws { try storage.delete(id) }
        func clear(for hostID: UUID) throws { try storage.clear(for: hostID) }
        func clearAll() throws {
            if failsClear { throw ReadFailure.unavailable }
            try storage.clearAll()
        }
    }

    private final class DeviceRepository: DeviceDirectoryRepository {
        let storage = InMemoryDeviceDirectoryRepository()
        var reads = 0
        var fails = false
        var failsWrites = false

        func devices() throws -> [DeviceRecord] {
            reads += 1
            if fails { throw ReadFailure.unavailable }
            return try storage.devices()
        }
        func upsert(_ device: DeviceRecord) throws {
            if failsWrites { throw ReadFailure.unavailable }
            try storage.upsert(device)
        }
    }
}
