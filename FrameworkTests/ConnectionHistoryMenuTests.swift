import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct ConnectionHistoryMenuTests {
    private let now = Date(timeIntervalSince1970: 1_791_288_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func launchRecordsExcludeSyncedEventsAndResetOnRestart() throws {
        let host = Host(name: "Server", host: "server.example")
        let local = UUID()
        let repository = InMemoryConnectionHistoryRepository()
        let history = ConnectionHistoryModel(repository: repository, sourceDeviceID: local)
        let devices = DeviceDirectoryModel(currentDeviceID: local)
        let library = HostLibraryModel(hosts: [host])
        let first = try #require(history.record(kind: .ssh, for: host.id, at: now))
        let second = try #require(history.record(kind: .sftp, for: host.id, at: now.addingTimeInterval(1)))
        let synced = ConnectionHistoryEntry(
            hostID: host.id, kind: .ssh, connectedAt: now.addingTimeInterval(2), sourceDeviceID: UUID())
        try repository.insert(synced, limit: ConnectionHistoryModel.limit)
        history.reload()

        let menu = ConnectionHistoryMenuSnapshot(
            history: history, library: library, devices: devices, now: now, calendar: calendar)
        #expect(menu.currentLaunch.map(\.id) == [second.id, first.id])
        #expect(menu.days.count == 1)
        #expect(menu.days.first?.isToday == true)
        #expect(menu.days.first?.rows.map(\.id) == [synced.id])

        let restarted = ConnectionHistoryModel(repository: repository, sourceDeviceID: local)
        let afterRestart = ConnectionHistoryMenuSnapshot(
            history: restarted, library: library, devices: devices, now: now, calendar: calendar)
        #expect(afterRestart.currentLaunch.isEmpty)
        #expect(afterRestart.days.first?.rows.map(\.id) == [synced.id, second.id, first.id])
    }

    @Test func dateGroupsFollowLocalDaysAndOmitMissingHosts() {
        let host = Host(name: "Server", host: "server.example")
        let today = calendar.startOfDay(for: now)
        let recent = ConnectionHistoryEntry(hostID: host.id, kind: .ssh, connectedAt: today.addingTimeInterval(60))
        let earlier = ConnectionHistoryEntry(hostID: host.id, kind: .sftp, connectedAt: today.addingTimeInterval(-60))
        let missing = ConnectionHistoryEntry(
            hostID: UUID(), kind: .ssh, connectedAt: today.addingTimeInterval(-200_000))
        let history = ConnectionHistoryModel(entries: [earlier, missing, recent])
        let devices = DeviceDirectoryModel()
        let library = HostLibraryModel(hosts: [host])
        let menu = ConnectionHistoryMenuSnapshot(
            history: history, library: library, devices: devices, now: now, calendar: calendar)
        #expect(menu.days.map(\.isToday) == [true, false])
        #expect(menu.days.flatMap(\.rows).map(\.id) == [recent.id, earlier.id])

        var shifted = calendar
        shifted.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let localMenu = ConnectionHistoryMenuSnapshot(
            history: history, library: library, devices: devices, now: today.addingTimeInterval(120), calendar: shifted)
        #expect(localMenu.days.count == 1)
        #expect(localMenu.days.first?.rows.map(\.id) == [recent.id, earlier.id])
        let tomorrow = ConnectionHistoryMenuSnapshot(
            history: history, library: library, devices: devices,
            now: today.addingTimeInterval(86_400), calendar: calendar)
        #expect(tomorrow.days.allSatisfy { !$0.isToday })
    }

    @Test func unavailableProtocolsStayVisibleAndClearRemovesBothSections() throws {
        var host = Host(name: "Server", host: "server.example")
        host.sshEnabled = false
        let old = ConnectionHistoryEntry(hostID: host.id, kind: .sftp, connectedAt: now)
        let history = ConnectionHistoryModel(entries: [old])
        let library = HostLibraryModel(hosts: [host])
        let devices = DeviceDirectoryModel()
        _ = try #require(history.record(kind: .ssh, for: host.id))
        let before = ConnectionHistoryMenuSnapshot(history: history, library: library, devices: devices)
        #expect(before.currentLaunch.first?.canOpen == false)
        #expect(before.days.first?.rows.first?.canOpen == false)
        history.clearAll()
        let after = ConnectionHistoryMenuSnapshot(history: history, library: library, devices: devices)
        #expect(after.currentLaunch.isEmpty && after.days.isEmpty)
        #expect(history.currentLaunchEntryIDs.isEmpty)
        #expect(library.host(host.id) != nil)
    }
}
