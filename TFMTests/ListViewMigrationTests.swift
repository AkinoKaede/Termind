import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
struct ListViewMigrationTests {
    @Test
    func assistantConversationIdentitySurvivesPresentationChanges() {
        let id = UUID()
        let normal = AssistantConversationListItem.conversation(
            id: id,
            title: "Chat",
            isArchived: false,
            isPinned: false,
            isStreaming: false,
            isCompacting: false,
            isSelected: false,
            isRenaming: false
        )
        let selected = AssistantConversationListItem.conversation(
            id: id,
            title: "Renamed",
            isArchived: false,
            isPinned: true,
            isStreaming: true,
            isCompacting: false,
            isSelected: true,
            isRenaming: true
        )

        #expect(normal.id == selected.id)
        #expect(normal != selected)
    }

    @Test
    func assistantSectionIdentityIsSeparateFromConversationIdentity() {
        let pinned = AssistantConversationListItem.section(.pinned)
        let collapsedPinned = AssistantConversationListItem.section(.pinned, count: 3)
        let chats = AssistantConversationListItem.section(.chats)
        let conversation = AssistantConversationListItem.conversation(
            id: UUID(), title: "Chat", isArchived: false, isPinned: false,
            isStreaming: false, isCompacting: false, isSelected: false,
            isRenaming: false
        )

        #expect(pinned.id != chats.id)
        #expect(pinned.id != conversation.id)
        #expect(pinned.id == collapsedPinned.id)
        #expect(pinned != collapsedPinned)
    }

    @Test
    func assistantDropResolverSupportsEmptyPinnedAndConversationMidpoints() throws {
        let first = UUID()
        let second = UUID()
        let items = [
            AssistantConversationListItem.section(.pinned),
            AssistantConversationListItem.section(.chats),
            .conversation(
                id: first, title: "First", isArchived: false, isPinned: false,
                isStreaming: false, isCompacting: false, isSelected: false,
                isRenaming: false
            ),
            .conversation(
                id: second, title: "Second", isArchived: false, isPinned: false,
                isStreaming: false, isCompacting: false, isSelected: false,
                isRenaming: false
            ),
        ]
        let frames = [
            CGRect(x: 0, y: 0, width: 200, height: 34),
            CGRect(x: 0, y: 34, width: 200, height: 34),
            CGRect(x: 0, y: 68, width: 200, height: 30),
            CGRect(x: 0, y: 98, width: 200, height: 30),
        ]

        let emptyPinned = try #require(
            AssistantConversationDropResolver.target(
                items: items, rowFrames: frames, pointerY: 16
            ))
        #expect(emptyPinned.section == .pinned)
        #expect(emptyPinned.beforeID == nil)

        let beforeSecond = try #require(
            AssistantConversationDropResolver.target(
                items: items, rowFrames: frames, pointerY: 100
            ))
        #expect(beforeSecond.section == .chats)
        #expect(beforeSecond.beforeID == second)

        let afterSecond = try #require(
            AssistantConversationDropResolver.target(
                items: items, rowFrames: frames, pointerY: 127
            ))
        #expect(afterSecond.section == .chats)
        #expect(afterSecond.beforeID == nil)
    }

    @Test
    func sftpScrollRequestsCanRepeatTheSameTarget() {
        let id = "/srv/example.txt"
        let first = SFTPFileScrollRequest(targetID: id, position: .nearest)
        let second = SFTPFileScrollRequest(targetID: id, position: .nearest)

        #expect(first.targetID == second.targetID)
        #expect(first.token != second.token)
    }

    @Test
    func transferCenterListHeightGrowsAndStopsAtItsScrollCap() {
        #expect(Metrics.TransferCenter.listHeight(itemCount: 1) == 104)
        #expect(Metrics.TransferCenter.listHeight(itemCount: 3) == 314)
        #expect(Metrics.TransferCenter.listHeight(itemCount: 5) == 420)
        #expect(Metrics.TransferCenter.listHeight(itemCount: 20) == 420)
    }

    @Test
    func slashMenuUsesExactCompactRowsAndScrollsAfterTen() {
        #expect(Metrics.Chat.slashMenuHeight(rowCount: 0) == 0)
        #expect(Metrics.Chat.slashMenuHeight(rowCount: 3) == 102)
        #expect(Metrics.Chat.slashMenuHeight(rowCount: 10) == 340)
        #expect(Metrics.Chat.slashMenuHeight(rowCount: 20) == 340)
    }

    @Test
    func sidebarHistoryKeepsIdentityWhileInlineEditingChanges() {
        let entry = CommandHistoryEntry(sessionID: UUID(), command: "pwd")
        let normal = SidebarListItem.history(entry, isNaming: false)
        let naming = SidebarListItem.history(entry, isNaming: true)

        #expect(normal.id == naming.id)
        #expect(normal != naming)
        #expect(normal.height == Metrics.Sidebar.historyCardHeight)
        #expect(naming.height == Metrics.Sidebar.historyCardEditingHeight)
        #expect(naming.height > normal.height)
    }

    /// The three histories are one card with three fillings, so a row is the
    /// same height whichever one it came from — and never zero, which is what a
    /// mismatched identity would produce after a collapse.
    @Test
    func everyHistoryKindSharesOneCardHeight() {
        let hostID = UUID()
        let connection = ConnectionHistoryEntry(hostID: hostID, kind: .ssh)
        let items: [SidebarListItem] = [
            .history(CommandHistoryEntry(sessionID: hostID, command: "pwd"), isNaming: false),
            .sftpHistory(
                SFTPHistoryEntry(sessionID: hostID, kind: .directory, path: "/var/log")
            ),
            .connection(
                connection,
                host: Host(id: hostID, name: "web-01", host: "web-01.example"),
                address: "deploy@web-01.example"
            ),
        ]

        for item in items {
            #expect(item.height == Metrics.Sidebar.historyCardHeight)
            #expect(item.height > 0)
        }
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test
    func historyIdentityIgnoresPresentationButNotTheRecord() {
        let host = Host(name: "web-01", host: "web-01.example")
        let entry = ConnectionHistoryEntry(hostID: host.id, kind: .ssh)
        let sameRecord = SidebarListItem.connection(
            entry, host: host, address: "root@web-01.example"
        )
        let renamedAddress = SidebarListItem.connection(
            entry, host: host, address: "deploy@web-01.example"
        )
        let otherRecord = SidebarListItem.connection(
            ConnectionHistoryEntry(hostID: host.id, kind: .ssh),
            host: host, address: "root@web-01.example"
        )
        let otherHost = SidebarListItem.connection(
            ConnectionHistoryEntry(hostID: UUID(), kind: .ssh),
            host: Host(name: "db-01", host: "db-01.example"),
            address: "deploy@db-01.example"
        )

        #expect(sameRecord.id == renamedAddress.id)
        #expect(sameRecord != renamedAddress)
        #expect(sameRecord.id != otherRecord.id)
        #expect(sameRecord.id != otherHost.id)
    }

    @Test
    func sidebarSectionIdentityDoesNotDependOnItsTitle() {
        let packageID = UUID()
        let short = SidebarListItem.section(.package(packageID), title: "Tools")
        let renamed = SidebarListItem.section(
            .package(packageID), title: "Operations", count: 3
        )

        #expect(short.id == renamed.id)
        #expect(short != renamed)
    }

    @Test
    func snippetSidebarExpansionIsIndependentAndRoundTrips() {
        let first = SidebarListItem.SectionID.package(UUID())
        let second = SidebarListItem.SectionID.package(UUID())
        var state = SnippetSidebarExpansionState()

        #expect(state.isExpanded(first))
        #expect(state.isExpanded(second))
        #expect(state.isExpanded(.ungrouped))

        state.setExpanded(false, for: first)
        state.setExpanded(false, for: .ungrouped)
        let restored = SnippetSidebarExpansionState(rawValue: state.rawValue)

        #expect(!restored.isExpanded(first))
        #expect(restored.isExpanded(second))
        #expect(!restored.isExpanded(.ungrouped))
        #expect(restored.isExpanded(.results))
    }

    @Test @MainActor
    func snippetSidebarAndMainPageKeepSeparateExpansionState() {
        let package = SnippetPackage(name: "Operations")
        let library = HostLibraryModel(snippetPackages: [package])
        let section = SidebarListItem.SectionID.package(package.id)
        var sidebar = SnippetSidebarExpansionState()

        sidebar.setExpanded(false, for: section)
        #expect(!sidebar.isExpanded(section))
        #expect(library.isSnippetPackageExpanded(package.id))

        library.setSnippetPackageExpanded(false, for: package.id)
        sidebar.setExpanded(true, for: section)
        #expect(sidebar.isExpanded(section))
        #expect(!library.isSnippetPackageExpanded(package.id))
    }

    @Test
    func snippetSidebarBuilderFoldsOnlyTheRequestedGroup() {
        let firstID = UUID()
        let secondID = UUID()
        let firstSnippet = Snippet(title: "First", body: "pwd")
        let secondSnippet = Snippet(title: "Second", body: "whoami")
        let groups = [
            SnippetSidebarGroup(
                id: .package(firstID), title: "Tools", snippets: [firstSnippet]
            ),
            SnippetSidebarGroup(
                id: .package(secondID), title: "Operations", snippets: [secondSnippet]
            ),
        ]
        var expansion = SnippetSidebarExpansionState()
        expansion.setExpanded(false, for: .package(firstID))

        let grouped = SnippetSidebarListBuilder.groupedItems(
            groups, expansion: expansion
        )
        #expect(
            grouped.map(\.id) == [
                .section(.package(firstID)),
                .section(.package(secondID)),
                .snippet(secondSnippet.id),
            ]
        )

        let search = SnippetSidebarListBuilder.searchItems(
            [firstSnippet, secondSnippet], title: "Results"
        )
        #expect(
            search.map(\.id) == [
                .section(.results),
                .snippet(firstSnippet.id),
                .snippet(secondSnippet.id),
            ]
        )
    }

    @Test @MainActor
    func terminalSidebarMenusKeepCopyInsertAndHistoryGroupingAligned() {
        let locale = Locale(identifier: "en")
        let snippet = Snippet(title: "Status", body: "uptime")
        var insertedSnippet: Snippet.ID?
        let snippetEntries = TerminalSidebarMenuBuilder.snippets(
            snippet: snippet, canInsert: true, locale: locale,
            copy: { _ in }, insert: { insertedSnippet = $0.id }
        )

        #expect(snippetEntries.map(\.title) == ["Copy", "Insert"])
        #expect(snippetEntries.allSatisfy { $0.isEnabled })
        snippetEntries[1].action()
        #expect(insertedSnippet == snippet.id)

        let disabledSnippetEntries = TerminalSidebarMenuBuilder.snippets(
            snippet: nil, canInsert: false, locale: locale,
            copy: { _ in }, insert: { _ in }
        )
        #expect(disabledSnippetEntries.map(\.title) == ["Copy", "Insert"])
        #expect(disabledSnippetEntries.allSatisfy { !$0.isEnabled })

        let history = CommandHistoryEntry(sessionID: UUID(), command: "whoami")
        let historyEntries = TerminalSidebarMenuBuilder.history(
            entry: history, canInsert: true, locale: locale,
            copy: { _ in }, insert: { _ in }, saveAsSnippet: { _ in }
        )
        #expect(
            historyEntries.map(\.title)
                == [
                    "Copy", "Insert", "Save as Snippet",
                ]
        )
        #expect(!historyEntries.contains { $0.isSeparator })

        let blankHistoryEntries = TerminalSidebarMenuBuilder.history(
            entry: nil, canInsert: false, locale: locale,
            copy: { _ in }, insert: { _ in }, saveAsSnippet: { _ in }
        )
        #expect(
            blankHistoryEntries.map(\.title)
                == ["Copy", "Insert", "Save as Snippet"]
        )
        #expect(blankHistoryEntries.prefix(3).allSatisfy { !$0.isEnabled })
    }
}

@Test
func sftpHistoryDisplayPathParticipatesInRowContentUpdates() {
    let entry = SFTPHistoryEntry(
        sessionID: UUID(), kind: .directory, path: "/home/deploy/project"
    )

    let absolute = SidebarListItem.sftpHistory(entry)
    let abbreviated = SidebarListItem.sftpHistory(entry, displayedPath: "~/project")

    #expect(absolute.id == abbreviated.id)
    #expect(absolute != abbreviated)
}
