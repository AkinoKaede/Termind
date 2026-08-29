import Foundation
import Testing

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

    /// Folding a section must not change the item's *value*, or ListViewKit
    /// reconfigures the header's hosting view from inside the click that asked
    /// for the fold — which crashed. Only the count is data; expansion is read
    /// by the row itself. See `AssistantSectionHeaderRow`.
    @Test
    func foldingASectionDoesNotChangeItsListItem() {
        let expanded = AssistantConversationListItem.section(.pinned, count: 3)
        let collapsed = AssistantConversationListItem.section(.pinned, count: 3)

        #expect(expanded == collapsed)
        #expect(
            AssistantConversationListItem.Section.pinned.expansionKey
                != AssistantConversationListItem.Section.chats.expansionKey
        )
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

        let emptyPinned = try #require(AssistantConversationDropResolver.target(
            items: items, rowFrames: frames, pointerY: 16
        ))
        #expect(emptyPinned.section == .pinned)
        #expect(emptyPinned.beforeID == nil)

        let beforeSecond = try #require(AssistantConversationDropResolver.target(
            items: items, rowFrames: frames, pointerY: 100
        ))
        #expect(beforeSecond.section == .chats)
        #expect(beforeSecond.beforeID == second)

        let afterSecond = try #require(AssistantConversationDropResolver.target(
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
    func settingsSelectionChangesContentWithoutChangingIdentity() {
        let normal = SettingsNavigationItem.section(.sftp, selected: false)
        let selected = SettingsNavigationItem.section(.sftp, selected: true)

        #expect(normal.id == selected.id)
        #expect(normal != selected)
    }

    @Test
    func sidebarHistoryKeepsIdentityWhileInlineEditingChanges() {
        let entry = CommandHistoryEntry(hostID: UUID(), command: "pwd")
        let normal = SidebarListItem.history(entry, isNaming: false)
        let naming = SidebarListItem.history(entry, isNaming: true)

        #expect(normal.id == naming.id)
        #expect(normal != naming)
        #expect(normal.height == Metrics.Sidebar.historyCardHeight)
        #expect(normal.height == 52)
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
            .history(CommandHistoryEntry(hostID: hostID, command: "pwd"), isNaming: false),
            .sftpHistory(
                SFTPHistoryEntry(hostID: hostID, kind: .directory, path: "/var/log")
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

        let search = SnippetSidebarListBuilder.searchItems([firstSnippet, secondSnippet])
        #expect(
            search.map(\.id) == [
                .section(.results),
                .snippet(firstSnippet.id),
                .snippet(secondSnippet.id),
            ]
        )
        }
    }

    @Test
    func sftpHistoryDisplayPathParticipatesInRowContentUpdates() {
        let entry = SFTPHistoryEntry(
            hostID: UUID(), kind: .directory, path: "/home/deploy/project"
        )

        let absolute = SidebarListItem.sftpHistory(entry)
        let abbreviated = SidebarListItem.sftpHistory(entry, displayedPath: "~/project")

        #expect(absolute.id == abbreviated.id)
        #expect(absolute != abbreviated)
    }
