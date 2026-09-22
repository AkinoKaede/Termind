import AppKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
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

    @Test
    @MainActor
    func menuBarBrandAssetLoadsAsATransparentTemplate() throws {
        let image = try #require(NSImage(named: "MenuBarIcon"))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let alpha = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.alphaComponent }
        }
        #expect(alpha.contains { $0 > 0.9 })
        #expect(alpha.filter { $0 < 0.1 }.count > alpha.count / 2)
    }

}
