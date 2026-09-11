import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure

#if canImport(AppKit)
    import AppKit
    import ListViewKit
    import Testing

    @testable import Termind

    @MainActor
    struct AssistantConversationListDropTests {
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
