// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindDomain
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct SFTPContextMenuTests {
    @Test func singleFileKeepsItsActionsAndOpenWithApplicationIcons() throws {
        let file = file("config.json")
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let application = SFTPFileApplication(
            url: URL(filePath: "/Applications/Editor.app"), name: "Editor", icon: icon, isDefault: true)
        var actions: [SFTPFileContextMenu.Action] = []
        let entries = snapshot(file).entries(applications: { _ in [application] }, perform: { actions.append($0) })
        let menu = NativeMenuEntry.menu(entries)
        #expect(
            menu.items.map(\.title) == [
                "Open", "Open With", "Download", "", "Copy", "Copy as", "Paste", "Rename",
                "Edit Permissions", "Delete", "", "New Folder", "Upload", "Refresh",
            ])
        #expect(!menu.autoenablesItems)
        let openWith = try #require(menu.items[1].submenu)
        #expect(openWith.items.map(\.title) == ["Editor (default)", "", "App Store…", "Other…"])
        #expect(openWith.items[0].image === icon)
        openWith.performActionForItem(at: 0)
        menu.performActionForItem(at: 9)
        #expect(actions == [.openWith(application.url), .delete])
        #expect(menu.items[9].image != nil)
        if #available(macOS 27.0, *) {
            #expect(menu.items[0].preferredImageVisibility == .automatic)
            #expect(menu.items[9].preferredImageVisibility == .automatic)
        }
        let copyAs = try #require(menu.items[5].submenu)
        #expect(copyAs.items.map(\.title) == ["Name", "Path"])
        #expect(copyAs.items.allSatisfy { $0.image == nil })
    }

    @Test func directoriesAndMultipleSelectionsDoNotDiscoverApplications() {
        let directory = file("folder", kind: .directory)
        let first = file("a.txt")
        let second = file("b.txt")
        var discoveries = 0
        let applications: @MainActor (String) -> [SFTPFileApplication] = { _ in
            discoveries += 1
            return []
        }
        let folderMenu = snapshot(directory).entries(applications: applications) { _ in }
        #expect(folderMenu.contains { $0.title == "Open" })
        #expect(!folderMenu.contains { $0.title == "Open With" })
        #expect(folderMenu.contains { $0.title == "Edit Permissions" })
        let multiple = snapshot(first, targets: [first, second]).entries(applications: applications) { _ in }
        #expect(
            multiple.map(\.title) == [
                "Download 2 Items", "", "Copy 2 Items", "Copy as", "Paste", "Delete 2 Items", "",
                "New Folder", "Upload", "Refresh",
            ])
        #expect(multiple[3].children.map(\.title) == ["Names", "Paths"])
        #expect(discoveries == 0)
    }

    @Test func connectionClipboardAndRefreshStateKeepTheirDisabledActions() throws {
        let disconnected = snapshot(file("README"), connected: false)
            .entries(applications: { _ in [] }, perform: { _ in })
        for title in ["Open With", "Paste", "Rename", "Edit Permissions", "Delete", "New Folder", "Upload", "Refresh"] {
            #expect(try #require(disconnected.first { $0.title == title }).isEnabled == false)
        }
        let openWith = try #require(disconnected.first { $0.title == "Open With" })
        #expect(openWith.children.map(\.title) == ["App Store…", "Other…"])
        #expect(!openWith.children[0].isEnabled)
        #expect(openWith.children[1].isEnabled)
        let loading = snapshot(file("a.txt"), canPaste: false, isLoading: true)
            .entries(applications: { _ in [] }, perform: { _ in })
        #expect(try #require(loading.first { $0.title == "Paste" }).isEnabled == false)
        #expect(try #require(loading.first { $0.title == "Refresh" }).isEnabled == false)
        #expect(try #require(loading.first { $0.title == "Rename" }).isEnabled)
    }

    @Test(arguments: [
        ("en", "Download 2 Items", "Copy 2 Items", "Delete 2 Items"),
        ("zh-Hans", "下载2项", "复制2项", "删除2项"),
        ("zh-Hant", "下載2項", "複製2項", "刪除2項"),
    ])
    func countedTitlesFollowTheAppLocale(_ language: String, _ download: String, _ copy: String, _ delete: String) {
        let first = file("a.txt")
        let menu = snapshot(first, targets: [first, file("b.txt")], locale: language)
            .entries(applications: { _ in [] }, perform: { _ in })
        #expect(menu[0].title == download)
        #expect(menu[2].title == copy)
        #expect(menu[5].title == delete)
    }

    @Test func rowReconfigurationDoesNotRebuildOrRetargetAnExistingMenu() throws {
        var target = "a.txt"
        var menuBuilds = 0
        var performed: [String] = []
        let row = HostingListRow(frame: CGRect(x: 0, y: 0, width: 400, height: 48))
        func content() -> AnyView {
            AnyView(
                Text(target).frame(width: 400, height: 48)
                    .overlay {
                        NativeRowContextMenu(
                            entries: {
                                menuBuilds += 1
                                let snapshot = target
                                return [NativeMenuEntry(title: snapshot) { performed.append(snapshot) }]
                            }, isPresented: .constant(false))
                    })
        }
        row.configure(rootView: content())
        row.layoutSubtreeIfNeeded()
        let source = try #require(findMenuView(row))
        let menu = try #require(source.makeMenu())
        let item = try #require(menu.items.first)

        target = "b.txt"
        row.configure(rootView: content())
        row.layoutSubtreeIfNeeded()
        #expect(menuBuilds == 1)
        #expect(menu.items.first === item)
        #expect(item.title == "a.txt")
        menu.performActionForItem(at: 0)
        #expect(performed == ["a.txt"])

        let nextMenu = try #require(findMenuView(row)?.makeMenu())
        #expect(nextMenu !== menu)
        #expect(nextMenu.items.first?.title == "b.txt")
        #expect(menuBuilds == 2)
        row.prepareForReuse()
        nextMenu.performActionForItem(at: 0)
        #expect(performed == ["a.txt", "b.txt"])
    }

    @Test func onlyContextClicksAreClaimedByTheMenuOverlay() throws {
        let cases: [(NSEvent.EventType, NSEvent.ModifierFlags, Bool)] = [
            (.rightMouseDown, [], true), (.rightMouseUp, [], true),
            (.leftMouseDown, .control, true), (.leftMouseUp, .control, true),
            (.leftMouseDown, [], false), (.leftMouseUp, [], false),
            (.leftMouseDown, .command, false), (.leftMouseDown, .shift, false),
            (.leftMouseDragged, [], false), (.mouseMoved, [], false),
        ]
        for (type, modifiers, expected) in cases {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            #expect(NativeRowContextMenu.RowMenuView.isContextMenuEvent(event) == expected)
        }
    }

    private func file(_ name: String, kind: RemoteFile.Kind = .file) -> RemoteFile {
        RemoteFile(
            path: "/home/\(name)", name: name, kind: kind,
            size: 10, permissions: 0o644, ownerUID: 0, ownerGID: 0)
    }

    private func snapshot(
        _ file: RemoteFile, targets: [RemoteFile]? = nil, connected: Bool = true,
        canPaste: Bool = true, isLoading: Bool = false, locale: String = "en"
    ) -> SFTPFileContextMenu {
        SFTPFileContextMenu(
            file: file, targets: targets ?? [file], connected: connected, allowsRemoteMutations: connected,
            canPaste: canPaste, isLoading: isLoading, locale: Locale(identifier: locale))
    }

    private func findMenuView(_ view: NSView) -> NativeRowContextMenu.RowMenuView? {
        if let menu = view as? NativeRowContextMenu.RowMenuView { return menu }
        return view.subviews.lazy.compactMap(findMenuView).first
    }
}
