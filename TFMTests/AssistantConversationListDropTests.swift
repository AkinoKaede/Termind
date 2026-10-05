import TermindApplication

#if canImport(AppKit)
    import AgentKit
    import AppKit
    import ListViewKit
    import SwiftUI
    import Testing

    @testable import Termind

    @MainActor
    struct AssistantConversationListDropTests {
        private func row(_ conversation: ConversationModel, renaming: Bool = false) -> AssistantConversationRow {
            AssistantConversationRow(
                conversation: conversation, isSelected: false, onOpen: {}, onDelete: {},
                isRenaming: renaming, renameTitle: .constant(""), onBeginRename: {},
                onCommitRename: {}, onCancelRename: {})
        }

        @Test(arguments: [AgentRunState.running, .waitingForApproval, .idle], [false, true])
        func activeRowsCanDragAndPinButRenameEditorsCannot(state: AgentRunState, compacting: Bool) throws {
            let conversation = ConversationModel(runState: state)
            if compacting { conversation.beginCompaction() }
            #expect(row(conversation).canDrag)
            #expect(!row(conversation, renaming: true).canDrag)
            let pin = try #require(row(conversation).contextMenu.first { $0.symbol == MenuSymbol.pin })
            #expect(pin.isEnabled)
            conversation.isPinned = true
            let unpin = try #require(row(conversation).contextMenu.first { $0.symbol == MenuSymbol.unpin })
            #expect(unpin.isEnabled)
            if state != .idle || compacting {
                let archive = try #require(row(conversation).contextMenu.first { $0.symbol == MenuSymbol.archive })
                #expect(!archive.isEnabled)
            }
        }

        @Test func archivedRowsCannotDragOrPin() {
            let conversation = ConversationModel()
            conversation.archivedAt = .now
            #expect(!row(conversation).canDrag)
            #expect(!row(conversation).contextMenu.contains { $0.symbol == MenuSymbol.pin })
        }

        @Test(arguments: [AgentRunState.running, .waitingForApproval, .idle], [false, true])
        func windowPinFallbackPreservesActivity(state: AgentRunState, compacting: Bool) {
            let conversation = ConversationModel(runState: state)
            if compacting { conversation.beginCompaction() }
            let library = AssistantLibraryModel(store: AssistantConversationStore(conversations: [conversation]))
            let window = WindowModel(assistantLibrary: library)
            window.toggleAssistantPin(conversation.id)
            #expect(conversation.isPinned)
            window.toggleAssistantPin(conversation.id)
            #expect(!conversation.isPinned)
            #expect(library.conversation(id: conversation.id) === conversation)
            #expect(conversation.runState == state)
            #expect(conversation.isCompacting == compacting)
        }

        /// The Assistant panel stacks the Workspace layer's chat list on top of
        /// the sidebar's and hides it with `opacity` and `allowsHitTesting`,
        /// neither of which AppKit consults when it picks a drag destination.
        /// The hidden copy used to win and draw its insertion line invisibly.
        @Test
        func hiddenConversationListLeavesTheDragToTheListOnScreen() {
            let container = AssistantConversationListContainer(
                listView: ListView<AssistantConversationListItem>()
            )
            container.frame = CGRect(x: 0, y: 0, width: 240, height: 400)
            let point = CGPoint(x: 120, y: 200)

            #expect(container.registeredDraggedTypes.contains(.string))
            #expect(container.hitTest(point) != nil)

            container.isInteractive = false

            #expect(container.registeredDraggedTypes.isEmpty)
            #expect(container.hitTest(point) == nil)

            container.isInteractive = true

            #expect(container.registeredDraggedTypes.contains(.string))
            #expect(container.hitTest(point) != nil)
        }
    }
#endif
