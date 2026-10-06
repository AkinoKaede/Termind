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

    @Test
    @MainActor
    func nativeMenuImagesAreAutomaticUnlessTheEntryOptsIn() throws {
        guard #available(macOS 27.0, *) else { return }

        let automatic = NativeMenuEntry(title: "Edit", symbol: MenuSymbol.edit).menuItem()
        let visible = NativeMenuEntry(
            title: "Delete", symbol: MenuSymbol.delete, imageVisibility: .visible
        ).menuItem()

        #expect(automatic.preferredImageVisibility == .automatic)
        #expect(visible.preferredImageVisibility == .visible)
        #expect(automatic.image != nil)
        #expect(visible.image != nil)
    }

    @Test
    @MainActor
    func swiftUIMenuMarkerOnlyRevealsMarkedImagesIncludingInSubmenus() throws {
        guard #available(macOS 27.0, *) else { return }

        let ordinary = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        ordinary.image = NSImage(systemSymbolName: MenuSymbol.edit, accessibilityDescription: nil)
        let delete = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
        delete.image = MenuImageVisibilityController.markedImage(systemName: MenuSymbol.delete)
        let clear = NSMenuItem(title: "Clear History", action: nil, keyEquivalent: "")
        clear.image = MenuImageVisibilityController.markedImage(systemName: MenuSymbol.clearHistory)
        let submenu = NSMenu()
        submenu.addItem(clear)
        let parent = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        let menu = NSMenu()
        menu.items = [ordinary, delete, parent]

        MenuImageVisibilityController.apply(to: menu)

        #expect(ordinary.preferredImageVisibility == .automatic)
        #expect(parent.preferredImageVisibility == .automatic)
        #expect(delete.preferredImageVisibility == .visible)
        #expect(clear.preferredImageVisibility == .visible)
    }

    @Test
    @MainActor
    func swiftUIMenuUpdatesReapplyVisibilityWhileTheMenuIsOpen() throws {
        guard #available(macOS 27.0, *) else { return }

        let notificationCenter = NotificationCenter()
        let controller = MenuImageVisibilityController()
        controller.start(notificationCenter: notificationCenter)
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
        delete.image = MenuImageVisibilityController.markedImage(systemName: MenuSymbol.delete)
        menu.addItem(delete)

        delete.preferredImageVisibility = .automatic
        notificationCenter.post(name: NSMenu.didChangeItemNotification, object: menu)
        #expect(delete.preferredImageVisibility == .visible)

        delete.preferredImageVisibility = .automatic
        notificationCenter.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(delete.preferredImageVisibility == .visible)
    }

}
