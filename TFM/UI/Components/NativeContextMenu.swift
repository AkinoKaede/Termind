import AppKit
import SwiftUI

/// A destructive action inside a SwiftUI context menu.
///
/// Carries `ButtonRole.destructive` and the trash glyph, and nothing else. The
/// title used to be painted red by hand, on both this and the AppKit side; that
/// made Delete the loudest thing in a menu it merely happens to end, and the red
/// was ours rather than the system's — it did not follow appearance, selection
/// highlight, or a disabled item. The role says what the item is and lets macOS
/// decide how to say it.
struct DestructiveMenuButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String = MenuSymbol.delete,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: systemImage, role: .destructive, action: action)
    }
}

/// One row of a hand-built native menu.
///
/// A value type rather than an `NSMenuItem` so callers never own a target, keep
/// a menu alive, or worry about when AppKit asks for it. Shared by the titlebar
/// search field's magnifier menu and by the blank-area menus in the sidebar and
/// on the manager pages.
struct NativeMenuEntry {
    var title: String
    /// The SF Symbol beside the title, from `MenuSymbol`. AppKit fills this in
    /// for standard actions and leaves ours empty, so every verb names its own.
    var symbol: String?
    var isOn = false
    var isEnabled = true
    var children: [NativeMenuEntry] = []
    var action: () -> Void = {}

    static let separator = NativeMenuEntry(title: "", isEnabled: false)

    var isSeparator: Bool { title.isEmpty }

    static func menu(_ entries: [NativeMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        fill(menu, with: entries)
        return menu
    }

    /// Replaces a long-lived menu's contents. `NSSearchField.searchMenuTemplate`
    /// is assigned once and refreshed in place — swapping the menu object while
    /// it is open takes it out from under itself.
    static func fill(_ menu: NSMenu, with entries: [NativeMenuEntry]) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for entry in entries {
            menu.addItem(entry.menuItem())
        }
    }

    func menuItem() -> NSMenuItem {
        guard !isSeparator else { return .separator() }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        if children.isEmpty {
            let target = NativeMenuActionTarget(action)
            item.representedObject = target
            item.target = target
            item.action = #selector(NativeMenuActionTarget.invoke)
            item.state = isOn ? .on : .off
            item.isEnabled = isEnabled
        } else {
            item.submenu = NativeMenuEntry.menu(children)
            item.isEnabled = isEnabled
        }
        return item
    }
}

/// Keeps a menu item's closure alive for exactly as long as the item.
///
/// `NSMenuItem.target` is unowned, so a temporary coordinator would be gone by
/// the time the user let go of the mouse. Parking it in `representedObject`
/// gives it the item's lifetime and nothing else's.
private final class NativeMenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() { action() }
}

/// A row's right-click menu, with the selection outline left to the caller.
///
/// SwiftUI's `contextMenu` draws its own source rectangle from the frame of the
/// view it is attached to, which in a sidebar row is the row *plus* the
/// breathing edge around it — a box visibly larger than the card it belongs to.
/// AppKit draws no source rectangle at all, so the row can outline itself
/// exactly on the filled shape.
struct NativeRowContextMenu: NSViewRepresentable {
    let entries: () -> [NativeMenuEntry]
    /// True while the menu is up, so the row can show it is the one acted on.
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> RowMenuView {
        RowMenuView()
    }

    func updateNSView(_ view: RowMenuView, context: Context) {
        view.entries = entries
        view.setPresented = { isPresented = $0 }
    }

    @MainActor
    final class RowMenuView: NSView, NSMenuDelegate {
        var entries: () -> [NativeMenuEntry] = { [] }
        var setPresented: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                event.type == .rightMouseDown || event.type == .rightMouseUp
            else { return nil }
            return super.hitTest(point) == nil ? nil : self
        }

        override func rightMouseDown(with event: NSEvent) {
            let items = entries()
            guard !items.isEmpty else { return }
            let menu = NativeMenuEntry.menu(items)
            menu.delegate = self
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        func menuWillOpen(_ menu: NSMenu) { setPresented(true) }

        func menuDidClose(_ menu: NSMenu) { setPresented(false) }
    }
}

/// A right-click-only overlay for the space *between* items.
///
/// Two things make this AppKit rather than a SwiftUI `contextMenu`. It has to
/// know where the pointer is, so a click that landed on a card can be declined
/// and handled by that card's own menu; and SwiftUI paints a source rectangle
/// for the whole view it is attached to, which on a page-sized container is the
/// whole page lighting up.
///
/// `hitTest` claims nothing but right-mouse events, and only where `claims` says
/// the point is empty, so every other event reaches the views underneath.
struct NativeBlankAreaMenu: NSViewRepresentable {
    /// Whether the blank-area menu owns this point, in the host's own flipped
    /// coordinates. Return false over an item that has a menu of its own.
    var claims: (CGPoint) -> Bool = { _ in true }
    /// Built fresh per click, so enabled states reflect the current selection.
    let entries: (CGPoint) -> [NativeMenuEntry]

    func makeNSView(context: Context) -> BlankAreaMenuView {
        BlankAreaMenuView()
    }

    func updateNSView(_ view: BlankAreaMenuView, context: Context) {
        view.claims = claims
        view.entries = entries
    }

    @MainActor
    final class BlankAreaMenuView: NSView {
        var claims: (CGPoint) -> Bool = { _ in true }
        var entries: (CGPoint) -> [NativeMenuEntry] = { _ in [] }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                event.type == .rightMouseDown || event.type == .rightMouseUp
            else { return nil }
            let local = convert(point, from: superview)
            guard bounds.contains(local), claims(local) else { return nil }
            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            let items = entries(local)
            guard !items.isEmpty else { return }
            NSMenu.popUpContextMenu(NativeMenuEntry.menu(items), with: event, for: self)
        }
    }
}
