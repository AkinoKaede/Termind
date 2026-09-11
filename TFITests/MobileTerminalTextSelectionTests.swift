import Foundation
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileTerminalTextSelectionTests {
    @Test func validAnchorRangeSelectsTheRequestedUTF16Text() {
        let text = "prompt 你好 world"
        let range = (text as NSString).range(of: "你好")
        let controller = MobileTerminalTextSelectionViewController(
            selection: MobileTerminalTextSelection(text: text, anchorRange: range)
        )

        controller.loadViewIfNeeded()
        controller.viewDidAppear(false)

        #expect(controller.textView.isSelectable)
        #expect(!controller.textView.isEditable)
        #expect(controller.textView.selectedRange == range)
    }

    @Test func missingAnchorRangeSelectsAllViewportText() {
        let text = "first line\nsecond line"
        let range = MobileTerminalTextSelectionViewController.resolvedSelectionRange(
            text: text,
            anchorRange: nil
        )

        #expect(range == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test func invalidAnchorRangeSelectsAllViewportText() {
        let text = "short"
        let range = MobileTerminalTextSelectionViewController.resolvedSelectionRange(
            text: text,
            anchorRange: NSRange(location: 4, length: 20)
        )

        #expect(range == NSRange(location: 0, length: (text as NSString).length))
    }
}
