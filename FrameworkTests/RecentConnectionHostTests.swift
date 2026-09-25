import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct RecentConnectionHostTests {
    @Test func projectionKeepsTheNewestLocalEventForEachSavedHost() {
        let localID = UUID()
        let first = Host(name: "First", host: "first.example")
        let second = Host(name: "Second", host: "second.example")
        let removedID = UUID()
        let firstOlder = ConnectionHistoryEntry(
            hostID: first.id, kind: .ssh,
            connectedAt: Date(timeIntervalSince1970: 10), sourceDeviceID: localID)
        let secondLatest = ConnectionHistoryEntry(
            hostID: second.id, kind: .telnet,
            connectedAt: Date(timeIntervalSince1970: 30), sourceDeviceID: localID)
        let firstLatest = ConnectionHistoryEntry(
            hostID: first.id, kind: .sftp,
            connectedAt: Date(timeIntervalSince1970: 20), sourceDeviceID: localID)
        let history = ConnectionHistoryModel(
            entries: [
                firstOlder,
                ConnectionHistoryEntry(
                    hostID: first.id, kind: .ssh,
                    connectedAt: Date(timeIntervalSince1970: 50), sourceDeviceID: UUID()),
                secondLatest,
                ConnectionHistoryEntry(
                    hostID: removedID, kind: .ssh,
                    connectedAt: Date(timeIntervalSince1970: 40), sourceDeviceID: localID),
                firstLatest,
                ConnectionHistoryEntry(
                    hostID: second.id, kind: .ssh,
                    connectedAt: Date(timeIntervalSince1970: 60)),
            ],
            sourceDeviceID: localID)
        let library = HostLibraryModel(hosts: [first, second])

        let all = history.recentLocalHosts(in: library, limit: 5)
        #expect(all.map(\.id) == [second.id, first.id])
        #expect(all.map(\.entry.id) == [secondLatest.id, firstLatest.id])
        #expect(all.map(\.host.name) == ["Second", "First"])
        #expect(history.recentLocalHosts(in: library, limit: 1).map(\.id) == [second.id])
        #expect(history.recentLocalHosts(in: library, limit: 0).isEmpty)
        #expect(history.recentLocalHosts(in: library, limit: -1).isEmpty)
    }
}
