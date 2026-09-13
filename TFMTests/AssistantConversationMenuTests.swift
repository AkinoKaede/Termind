import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct AssistantConversationMenuTests {
    @Test
    func deleteIsOnlyOfferedForArchivedConversations() {
        let conversation = ConversationModel()
        var row = conversationRow(conversation)

        #expect(row.contextMenu.contains { $0.symbol == MenuSymbol.archive })
        #expect(!row.contextMenu.contains { $0.symbol == MenuSymbol.delete })

        conversation.archivedAt = .now
        row = conversationRow(conversation)

        #expect(row.contextMenu.contains { $0.symbol == MenuSymbol.unarchive })
        #expect(row.contextMenu.contains { $0.symbol == MenuSymbol.delete })
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
