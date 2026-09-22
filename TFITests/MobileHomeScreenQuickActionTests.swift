import Foundation
import TermindApplication
import TermindDomain
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileHomeScreenQuickActionTests {
    @Test func descriptorsUseTheNewestThreeUniqueLocalHosts() throws {
        let app = try MobileAppModel(inMemory: true)
        let repeated = Host(
            name: "Production", host: "production.example.invalid",
            telnetEnabled: true)
        let others = (0..<3).map { Host(name: "Host \($0)", host: "host-\($0).example.invalid") }
        app.library.upsert(repeated)
        for host in others { app.library.upsert(host) }

        _ = app.connectionHistory.record(
            kind: .ssh, for: repeated.id, at: Date(timeIntervalSince1970: 60))
        _ = app.connectionHistory.record(
            kind: .ssh, for: repeated.id, at: Date(timeIntervalSince1970: 50))
        _ = app.connectionHistory.record(
            kind: .telnet, for: repeated.id, at: Date(timeIntervalSince1970: 45))
        _ = app.connectionHistory.record(
            kind: .sftp, for: repeated.id, at: Date(timeIntervalSince1970: 40))
        _ = app.connectionHistory.record(
            kind: .ssh, for: others[0].id, at: Date(timeIntervalSince1970: 30))
        _ = app.connectionHistory.record(
            kind: .sftp, for: others[1].id, at: Date(timeIntervalSince1970: 20))
        _ = app.connectionHistory.record(
            kind: .ssh, for: others[2].id, at: Date(timeIntervalSince1970: 10))
        _ = app.connectionHistory.record(
            kind: .ssh, for: UUID(), at: Date(timeIntervalSince1970: 70))

        let rows = MobileConnectionHistory.recentHostRows(
            entries: app.connectionHistory.localEntries(),
            library: app.library,
            limit: ConnectionHistoryModel.limit
        )
        let descriptors = MobileHomeScreenQuickActions.descriptors(rows: rows)

        #expect(descriptors.count == 3)
        #expect(
            descriptors.map(\.action)
                == [
                    .history(hostID: repeated.id),
                    .history(hostID: others[0].id),
                    .history(hostID: others[1].id),
                ])
        #expect(descriptors.map(\.title) == ["Production", "Host 0", "Host 1"])
        #expect(descriptors.allSatisfy { $0.symbol == "server.rack" })
        #expect(UIImage(systemName: descriptors[1].symbol) != nil)
        #expect(descriptors[1].shortcutItem.icon != nil)
    }

    @Test func historyShortcutPayloadRoundTripsAndMalformedItemsAreRejected() throws {
        let hostID = UUID()
        let host = Host(id: hostID, name: "Files", host: "files.example.invalid")
        let row = MobileRecentHostRow(
            entry: ConnectionHistoryEntry(hostID: hostID, kind: .sftp),
            host: host,
            loginAddress: "files.example.invalid",
            preferredKind: .ssh
        )
        let descriptor = try #require(
            MobileHomeScreenQuickActions.descriptors(rows: [row]).first)
        let shortcutItem = descriptor.shortcutItem

        #expect(shortcutItem.type == MobileHomeScreenQuickActions.historyType)
        #expect(shortcutItem.localizedTitle == "Files")
        #expect(shortcutItem.localizedSubtitle == nil)
        #expect(shortcutItem.icon != nil)
        #expect(
            MobileHomeScreenQuickActions.action(from: shortcutItem)
                == .history(hostID: hostID))

        let legacy = UIApplicationShortcutItem(
            type: MobileHomeScreenQuickActions.historyType,
            localizedTitle: "Legacy",
            localizedSubtitle: nil,
            icon: nil,
            userInfo: [
                MobileHomeScreenQuickActions.hostIDKey: hostID.uuidString as NSString,
                MobileHomeScreenQuickActions.kindKey: ConnectionHistoryEntry.Kind.sftp.rawValue as NSString,
            ])
        #expect(MobileHomeScreenQuickActions.action(from: legacy) == .history(hostID: hostID))

        let malformed = UIApplicationShortcutItem(
            type: MobileHomeScreenQuickActions.historyType,
            localizedTitle: "Malformed"
        )
        let unknown = UIApplicationShortcutItem(type: "unknown", localizedTitle: "Unknown")
        #expect(MobileHomeScreenQuickActions.action(from: malformed) == nil)
        #expect(MobileHomeScreenQuickActions.action(from: unknown) == nil)
    }

    @Test func sceneDelegateAcceptsKnownActionsAndConsumesEachOnce() {
        let delegate = MobileSceneDelegate()
        let connect = UIApplicationShortcutItem(
            type: MobileHomeScreenQuickActions.connectType,
            localizedTitle: "Connect"
        )

        #expect(delegate.receive(connect))
        #expect(delegate.pendingQuickAction == .connect)
        #expect(delegate.consumePendingQuickAction() == .connect)
        #expect(delegate.consumePendingQuickAction() == nil)

        let unknown = UIApplicationShortcutItem(type: "unknown", localizedTitle: "Unknown")
        #expect(!delegate.receive(unknown))
        #expect(delegate.pendingQuickAction == nil)
    }
}
