import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized, .requiresVisibleWindow)
@MainActor
struct HistoryMenuTests {
    @Test func historyMenuPrecedesWindowAndKeepsItsShortcutsAndImagePolicy() async throws {
        var history: NSMenu?
        for _ in 0..<40 {
            history = NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.items.contains { $0.keyEquivalent == "y" }
            }
            if history != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let menu = try #require(history)
        let main = try #require(NSApp.mainMenu)
        let index = try #require(main.items.firstIndex { $0.submenu === menu })
        let windowIndex = try #require(main.items.firstIndex { $0.submenu === NSApp.windowsMenu })
        #expect(index + 1 == windowIndex)
        let rows = menu.items.filter { !$0.isSeparatorItem }
        try #require(rows.count >= 4)
        let show = try #require(rows.first)
        #expect(show.title == String(localized: AppStrings.History.showHistory))
        #expect(show.keyEquivalent == "y")
        #expect(show.keyEquivalentModifierMask == .command)
        #expect(rows[1].title == String(localized: AppStrings.History.recentClosed))
        #expect(rows[1].submenu != nil)
        #expect(rows[2].title == String(localized: AppStrings.Workspace.reopenClosedWorkspace))
        #expect(rows[2].keyEquivalent == "T" || rows[2].keyEquivalent == "t")
        #expect(rows.last?.title == String(localized: AppStrings.Common.clearHistory))
        #expect(show.image != nil)
        if #available(macOS 27.0, *) {
            MenuImageVisibilityController.apply(to: menu)
            #expect(show.preferredImageVisibility == .visible)
            #expect(rows[1].image == nil)
            #expect(rows[2].image == nil)
            #expect(rows.last?.image == nil)
        } else {
            #expect(rows.allSatisfy { $0.image != nil })
        }
        let reopenTitles = main.items.compactMap(\.submenu).flatMap(\.items).filter {
            $0.title == String(localized: AppStrings.Workspace.reopenClosedWorkspace)
        }
        #expect(reopenTitles.count == 1)
    }
}

@Suite @MainActor
struct HistoryMenuRecordTests {
    @Test func closedWindowLabelsUseTheFirstNameAndCorrectPlural() {
        func title(_ count: Int) -> String {
            var value = AppStrings.History.closedWindow("Server", count: count)
            value.locale = Locale(identifier: "en")
            return String(localized: value)
        }
        #expect(title(1) == "Server")
        #expect(title(2) == "Server (and 1 more workspace)")
        #expect(title(3) == "Server (and 2 more workspaces)")
    }

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
            history: history, library: HostLibraryModel(hosts: [host]), devices: DeviceDirectoryModel(), now: now)
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
