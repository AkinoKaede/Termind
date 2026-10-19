import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct HistoryMenuRecordTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func nativeRecordMenusKeepProtocolImagesAndOpenTheChosenEvent(language: String) throws {
        let host = Host(name: "Server", host: "server.example")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(43_200)
        let today = Calendar.current.startOfDay(for: now)
        let earlier = ConnectionHistoryEntry(hostID: host.id, kind: .sftp, connectedAt: today.addingTimeInterval(1))
        let yesterday = ConnectionHistoryEntry(hostID: host.id, kind: .ssh, connectedAt: today.addingTimeInterval(-1))
        let recent = (1...14).map {
            ConnectionHistoryEntry(hostID: host.id, kind: .ssh, connectedAt: today.addingTimeInterval(Double($0 * 60)))
        }
        let history = ConnectionHistoryModel(entries: [earlier, yesterday] + recent)
        let current = try #require(history.record(kind: .ssh, for: host.id, at: now))
        let snapshot = ConnectionHistoryMenuSnapshot(
            history: history, library: HostLibraryModel(hosts: [host]), now: now)
        var opened: [UUID] = []
        let menu = NSHostingMenu(
            rootView: HistoryMenuRecords(
                snapshot: snapshot,
                image: { Image(nsImage: MenuImageVisibilityController.markedImage(systemName: $0)) }
            ) { opened.append($0.id) }
            .environment(\.locale, Locale(identifier: language)))
        menu.update()
        MenuImageVisibilityController.apply(to: menu)
        let items = menu.items.filter { !$0.isSeparatorItem }
        try #require(items.count == 17)
        let currentItem = try #require(items.first)
        #expect(currentItem.title == host.name)
        #expect(currentItem.image != nil)
        let todayMenu = try #require(items[15].submenu)
        todayMenu.update()
        MenuImageVisibilityController.apply(to: todayMenu)
        let sftpItem = try #require(todayMenu.items.first)
        #expect(sftpItem.title == host.name)
        #expect(sftpItem.image != nil)
        #expect(currentItem.image?.name() != sftpItem.image?.name())
        if #available(macOS 27.0, *) {
            #expect(currentItem.preferredImageVisibility == .visible)
            #expect(sftpItem.preferredImageVisibility == .visible)
        }
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0 === currentItem }))
        todayMenu.performActionForItem(at: 0)
        #expect(opened == [current.id, earlier.id])
    }
}
