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

    @Test func todayIncludesSyncedEventsAndDoesNotChangeOnRestart() throws {
        let host = Host(name: "Server", host: "server.example")
        let local = UUID()
        let repository = InMemoryConnectionHistoryRepository()
        let history = ConnectionHistoryModel(repository: repository, sourceDeviceID: local)
        let library = HostLibraryModel(hosts: [host])
        let first = try #require(history.record(kind: .ssh, for: host.id, at: now))
        let second = try #require(history.record(kind: .sftp, for: host.id, at: now.addingTimeInterval(1)))
        let synced = ConnectionHistoryEntry(
            hostID: host.id, kind: .ssh, connectedAt: now.addingTimeInterval(2), sourceDeviceID: UUID())
        try repository.insert(synced, limit: ConnectionHistoryModel.limit)
        history.reload()

        let menu = ConnectionHistoryMenuSnapshot(
            history: history, library: library, now: now, calendar: calendar)
        #expect(menu.recentToday.map(\.id) == [synced.id, second.id, first.id])
        #expect(menu.days.isEmpty)

        let restarted = ConnectionHistoryModel(repository: repository, sourceDeviceID: local)
        let afterRestart = ConnectionHistoryMenuSnapshot(
            history: restarted, library: library, now: now, calendar: calendar)
        #expect(afterRestart.recentToday.map(\.id) == [synced.id, second.id, first.id])
        #expect(afterRestart.days.isEmpty)
    }

    @Test func todayOverflowMovesIntoDateGroupsWithoutLosingOrDuplicatingRecords() throws {
        let host = Host(name: "Server", host: "server.example")
        let history = ConnectionHistoryModel()
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(history.record(kind: .ssh, for: host.id, at: today.addingTimeInterval(-60)))
        let entries = try (0..<18).map { index in
            try #require(history.record(kind: .ssh, for: host.id, at: today.addingTimeInterval(Double(index + 1))))
        }
        let menu = ConnectionHistoryMenuSnapshot(
            history: history, library: HostLibraryModel(hosts: [host]),
            now: today.addingTimeInterval(3600), calendar: calendar)
        #expect(menu.recentToday.map(\.id) == entries.suffix(15).reversed().map(\.id))
        #expect(menu.days.map(\.isToday) == [true, false])
        #expect(menu.days.first?.rows.map(\.id) == entries.prefix(3).reversed().map(\.id))
        #expect(menu.days.last?.rows.map(\.id) == [yesterday.id])
        let displayed = menu.recentToday + menu.days.flatMap(\.rows)
        #expect(displayed.count == history.entries().count)
        #expect(Set(displayed.map(\.id)).count == displayed.count)
    }

    @Test func dateGroupsFollowLocalDaysAndOmitMissingHosts() {
        let host = Host(name: "Server", host: "server.example")
        let today = calendar.startOfDay(for: now)
        let recent = ConnectionHistoryEntry(hostID: host.id, kind: .ssh, connectedAt: today.addingTimeInterval(60))
        let earlier = ConnectionHistoryEntry(hostID: host.id, kind: .sftp, connectedAt: today.addingTimeInterval(-60))
        let missing = ConnectionHistoryEntry(
            hostID: UUID(), kind: .ssh, connectedAt: today.addingTimeInterval(-200_000))
        let history = ConnectionHistoryModel(entries: [earlier, missing, recent])
        let library = HostLibraryModel(hosts: [host])
        let menu = ConnectionHistoryMenuSnapshot(
            history: history, library: library, now: now, calendar: calendar)
        #expect(menu.recentToday.map(\.id) == [recent.id])
        #expect(menu.days.map(\.isToday) == [false])
        #expect(menu.days.flatMap(\.rows).map(\.id) == [earlier.id])

        var shifted = calendar
        shifted.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let localMenu = ConnectionHistoryMenuSnapshot(
            history: history, library: library, now: today.addingTimeInterval(120), calendar: shifted)
        #expect(localMenu.days.isEmpty)
        #expect(localMenu.recentToday.map(\.id) == [recent.id, earlier.id])
        let tomorrow = ConnectionHistoryMenuSnapshot(
            history: history, library: library,
            now: today.addingTimeInterval(86_400), calendar: calendar)
        #expect(tomorrow.recentToday.isEmpty)
        #expect(tomorrow.days.allSatisfy { !$0.isToday })
    }

    @Test func unavailableProtocolsStayVisibleAndClearRemovesBothSections() throws {
        var host = Host(name: "Server", host: "server.example")
        host.sshEnabled = false
        let old = ConnectionHistoryEntry(
            hostID: host.id, kind: .sftp, connectedAt: calendar.startOfDay(for: now).addingTimeInterval(-60))
        let history = ConnectionHistoryModel(entries: [old])
        let library = HostLibraryModel(hosts: [host])
        _ = try #require(history.record(kind: .ssh, for: host.id, at: now))
        let before = ConnectionHistoryMenuSnapshot(
            history: history, library: library, now: now, calendar: calendar)
        #expect(before.recentToday.first?.canOpen == false)
        #expect(before.days.first?.rows.first?.canOpen == false)
        history.clearAll()
        let after = ConnectionHistoryMenuSnapshot(
            history: history, library: library, now: now, calendar: calendar)
        #expect(after.recentToday.isEmpty && after.days.isEmpty)
        #expect(library.host(host.id) != nil)
    }
}
