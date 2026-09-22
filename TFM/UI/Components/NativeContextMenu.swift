import AppKit
import SwiftUI

/// A destructive action inside a SwiftUI menu.
///
/// macOS 27 normally hides menu item images. Delete and permanent Clear actions
/// are the exceptions in Termind: their named images let the native menu bridge
/// request `.visible` without guessing from a localized title. The role still
/// lets macOS own the destructive presentation.
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
        Button(role: .destructive, action: action) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuImageVisibilityController.markedImage(systemName: systemImage))
            }
        }
    }
}

/// Whether an AppKit-built menu item should follow the system or keep its image.
enum MenuImageVisibility: Equatable {
    case automatic
    case visible
}

/// Applies macOS 27's opt-in menu image visibility to SwiftUI-generated menus.
///
/// SwiftUI does not expose `NSMenuItem.preferredImageVisibility`. A named image
/// survives SwiftUI's conversion to `NSMenuItem`, giving this observer a narrow,
/// semantic marker that does not depend on English titles or SF Symbol artwork.
@MainActor
final class MenuImageVisibilityController: NSObject {
    static let shared = MenuImageVisibilityController()

    private static let markerPrefix = "termind.menu.always-visible."
    private var isStarted = false
    private var notificationCenter: NotificationCenter?

    static func markedImage(systemName: String) -> NSImage {
        let markerName = NSImage.Name(markerPrefix + systemName)
        if let image = NSImage(named: markerName) { return image }
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return NSImage()
        }
        _ = image.setName(markerName)
        return image
    }

    func start(notificationCenter: NotificationCenter = .default) {
        guard !isStarted else { return }
        isStarted = true
        self.notificationCenter = notificationCenter
        for name in [
            NSMenu.didBeginTrackingNotification,
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
        ] {
            notificationCenter.addObserver(
                self,
                selector: #selector(menuContentsChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    static func apply(to menu: NSMenu) {
        guard #available(macOS 27.0, *) else { return }
        for item in menu.items {
            if item.image?.name()?.hasPrefix(markerPrefix) == true,
                item.preferredImageVisibility != .visible
            {
                item.preferredImageVisibility = .visible
            }
            if let submenu = item.submenu {
                apply(to: submenu)
            }
        }
    }

    @objc private func menuContentsChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        Self.apply(to: menu)
    }

    deinit {
        notificationCenter?.removeObserver(self)
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
    var image: NSImage?
    var imageVisibility = MenuImageVisibility.automatic
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
        item.image =
            image
            ?? symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
        if #available(macOS 27.0, *), imageVisibility == .visible {
            item.preferredImageVisibility = .visible
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
            guard let event = NSApp.currentEvent, Self.isContextMenuEvent(event)
            else { return nil }
            return super.hitTest(point) == nil ? nil : self
        }

        static func isContextMenuEvent(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp: true
            case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
            default: false
            }
        }

        override func mouseDown(with event: NSEvent) {
            if Self.isContextMenuEvent(event) {
                rightMouseDown(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = makeMenu() else { return }
            // Keep this menu independent of subsequent SwiftUI row updates.
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        func makeMenu() -> NSMenu? {
            let items = entries()
            guard !items.isEmpty else { return nil }
            let menu = NativeMenuEntry.menu(items)
            menu.delegate = self
            return menu
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
