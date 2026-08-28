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

    @Test
    func assistantSectionIdentityIsSeparateFromConversationIdentity() {
        let pinned = AssistantConversationListItem.section(.pinned)
        let chats = AssistantConversationListItem.section(.chats)
        let conversation = AssistantConversationListItem.conversation(
            id: UUID(), title: "Chat", isArchived: false, isPinned: false,
            isStreaming: false, isCompacting: false, isSelected: false,
            isRenaming: false
        )

        #expect(pinned.id != chats.id)
        #expect(pinned.id != conversation.id)
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
    func contextSidebarHistoryKeepsIdentityWhileInlineEditingChanges() {
        let entry = CommandHistoryEntry(hostID: UUID(), command: "pwd")
        let normal = ContextSidebarListItem.history(entry, isNaming: false)
        let naming = ContextSidebarListItem.history(entry, isNaming: true)

        #expect(normal.id == naming.id)
        #expect(normal != naming)
        #expect(normal.height < naming.height)
    }

    @Test
    func contextSidebarSectionIdentityDoesNotDependOnItsTitle() {
        let packageID = UUID()
        let short = ContextSidebarListItem.section(.package(packageID), title: "Tools")
        let renamed = ContextSidebarListItem.section(.package(packageID), title: "Operations")

        #expect(short.id == renamed.id)
        #expect(short != renamed)
    }
}
