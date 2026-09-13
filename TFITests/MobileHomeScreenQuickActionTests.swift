import Foundation
import TermindDomain
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileHomeScreenQuickActionTests {
    @Test func descriptorsUseTheNewestThreeUniqueValidHistoryRows() throws {
        let app = try MobileAppModel(inMemory: true)
        let repeated = Host(name: "Production", host: "production.example.invalid")
        let others = (0..<3).map { Host(name: "Host \($0)", host: "host-\($0).example.invalid") }
        app.library.upsert(repeated)
        for host in others { app.library.upsert(host) }

        _ = app.connectionHistory.record(
            kind: .ssh, for: repeated.id, at: Date(timeIntervalSince1970: 60))
        _ = app.connectionHistory.record(
            kind: .ssh, for: repeated.id, at: Date(timeIntervalSince1970: 50))
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

        let rows = MobileConnectionHistory.rows(
            entries: app.connectionHistory.entries(),
            library: app.library,
            limit: MobileHomeScreenQuickActions.historyLimit
        )
        let descriptors = MobileHomeScreenQuickActions.descriptors(rows: rows)

        #expect(descriptors.count == 3)
        #expect(
            descriptors.map(\.action)
                == [
                    .history(hostID: repeated.id, kind: .ssh),
                    .history(hostID: repeated.id, kind: .sftp),
                    .history(hostID: others[0].id, kind: .ssh),
                ])
        #expect(descriptors.map(\.title) == ["Production", "Production", "Host 0"])
        #expect(descriptors.map(\.symbol) == ["terminal", "folder", "terminal"])
    }

    @Test func historyShortcutPayloadRoundTripsAndMalformedItemsAreRejected() throws {
        let hostID = UUID()
        let row = MobileConnectionHistoryRow(
            entry: ConnectionHistoryEntry(hostID: hostID, kind: .sftp),
            host: Host(id: hostID, name: "Files", host: "files.example.invalid"),
            loginAddress: "deploy@files.example.invalid"
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
                == .history(hostID: hostID, kind: .sftp))

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
