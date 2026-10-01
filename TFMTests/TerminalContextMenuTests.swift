import AppKit
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalContextMenuTests {
    @Test func defaultMenuValidatesPasteAndOptionBypassesAutomaticPaste() throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(
                saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
        }
        let view = TermindTerminalView(frame: .zero)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        pasteboard.clearContents()
        let emptyMenu = try #require(view.menu(for: event))
        let pasteTitle = String(localized: AppStrings.Common.paste)
        #expect(emptyMenu.item(withTitle: pasteTitle)?.isEnabled == false)
        #expect(emptyMenu.items.contains { $0.action == #selector(view.selectAll(_:)) && $0.isEnabled })
        #expect(!emptyMenu.items.contains { $0.action == #selector(view.copy(_:)) })

        pasteboard.setString("echo hello", forType: .string)
        #expect(view.menu(for: event)?.item(withTitle: pasteTitle)?.isEnabled == true)
        view.pasteOnRightClick = true
        #expect(view.menu(for: event) == nil)
        let optionEvent = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: .option, timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(view.menu(for: optionEvent)?.item(withTitle: pasteTitle)?.isEnabled == true)
    }
}
