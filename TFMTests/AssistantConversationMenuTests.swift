import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct AssistantConversationMenuTests {
    @Test
    func archiveStateIsSharedWhileSidebarActionKeepsWorkspaceInFront() throws {
        let host = Host(name: "Server", host: "server.example.invalid")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace])

        window.showAssistantArchive()
        window.select(workspace.id)

        let fullScreenArchive = try #require(
            AssistantConversationMenuSurface.fullScreen
                .blankAreaMenu(in: window, locale: Locale(identifier: "en"))
                .first { $0.symbol == MenuSymbol.archive }
        )
        let sidebarArchive = try #require(
            AssistantConversationMenuSurface.sidebar
                .blankAreaMenu(in: window, locale: Locale(identifier: "en"))
                .first { $0.symbol == MenuSymbol.archive }
        )

        #expect(fullScreenArchive.isOn)
        #expect(sidebarArchive.isOn)

        window.closeAssistantInSidebar()

        #expect(!window.isAssistantArchivePresented)

        sidebarArchive.action()

        #expect(window.selectedDestination == .workspace(workspace.id))
        #expect(window.isAssistantArchivePresented)
    }

    @Test
    func deleteIsOnlyOfferedForArchivedConversations() {
        let conversation = ConversationModel()
        var row = conversationRow(conversation)

        #expect(row.contextMenu.contains { $0.symbol == MenuSymbol.archive })
        #expect(!row.contextMenu.contains { $0.symbol == MenuSymbol.delete })

        conversation.archivedAt = .now
        row = conversationRow(conversation)

        #expect(row.contextMenu.contains { $0.symbol == MenuSymbol.unarchive })
        #expect(
            row.contextMenu.contains {
                $0.symbol == MenuSymbol.delete && $0.imageVisibility == .visible
            })
    }

    private func conversationRow(_ conversation: ConversationModel) -> AssistantConversationRow {
        AssistantConversationRow(
            conversation: conversation,
            isSelected: false,
            onOpen: {},
            onDelete: {},
            isRenaming: false,
            renameTitle: .constant(""),
            onBeginRename: {},
            onCommitRename: {},
            onCancelRename: {}
        )
    }
}
