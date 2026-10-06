import AppKit
import Foundation
import TermindApplication
import Testing

@testable import Termind

@Suite
struct MenuSymbolTests {
    /// A misspelled SF Symbol draws nothing and reports nothing, so the menu
    /// simply loses one glyph and no one finds out. This is the only place that
    /// notices.
    @Test
    func everyGlyphResolvesToASystemSymbol() {
        for name in MenuSymbol.all {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not an SF Symbol"
            )
        }
    }

    @Test @MainActor
    func nativeMenuImagesFollowSystemVisibilityIncludingDestructiveActions() {
        guard #available(macOS 27.0, *) else { return }
        let menu = NativeMenuEntry.menu([
            NativeMenuEntry(title: "Edit", symbol: MenuSymbol.edit),
            NativeMenuEntry(title: "Delete", symbol: MenuSymbol.delete),
            NativeMenuEntry(title: "Clear History", symbol: MenuSymbol.clearHistory),
        ])
        #expect(menu.items.allSatisfy { $0.image != nil && $0.preferredImageVisibility == .automatic })
    }
    @Test @MainActor
    func onlyMarkedHistoryImagesAreForcedVisibleIncludingSubmenus() {
        guard #available(macOS 27.0, *) else { return }
        let show = NSMenuItem(title: "Show History", action: nil, keyEquivalent: "y")
        show.image = MenuImageVisibilityController.markedImage(systemName: "clock.arrow.circlepath")
        let record = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
        record.image = MenuImageVisibilityController.markedImage(systemName: "terminal")
        let day = NSMenuItem(title: "Earlier Today", action: nil, keyEquivalent: "")
        day.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        day.submenu = NSMenu()
        day.submenu?.addItem(record)
        let clear = NativeMenuEntry(title: "Clear History", symbol: MenuSymbol.clearHistory).menuItem()
        let menu = NSMenu()
        menu.items = [show, day, clear]
        MenuImageVisibilityController.apply(to: menu)
        #expect(show.preferredImageVisibility == .visible)
        #expect(record.preferredImageVisibility == .visible)
        #expect(day.preferredImageVisibility == .automatic)
        #expect(clear.preferredImageVisibility == .automatic)
    }
}
