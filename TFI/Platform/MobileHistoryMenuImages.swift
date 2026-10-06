import UIKit

/// iPadOS 27 hides automatic menu images. Keep the History menu's protocol and action images visible.
@MainActor
enum MobileHistoryMenuImages {
    static func apply(to builder: any UIMenuBuilder) {
        guard #available(iOS 27.0, *), builder.system === UIMenuSystem.main,
            let root = builder.menu(for: .root)
        else { return }
        for menu in root.children.compactMap({ $0 as? UIMenu }) where containsHistoryShortcut(menu) {
            revealImages(in: menu)
            builder.replace(menu: menu.identifier, with: menu)
        }
    }

    // Identify the command independently of the app language and SwiftUI-generated menu identifiers.
    static func containsHistoryShortcut(_ menu: UIMenu) -> Bool {
        menu.children.contains { element in
            if let command = element as? UIKeyCommand {
                return command.input?.lowercased() == "y" && command.modifierFlags == .command
            }
            return (element as? UIMenu).map(containsHistoryShortcut) ?? false
        }
    }

    static func revealImages(in menu: UIMenu) {
        guard #available(iOS 27.0, *) else { return }
        if menu.image != nil { menu.preferredImageVisibility = .visible }
        for element in menu.children {
            if element.image != nil { element.preferredImageVisibility = .visible }
            if let submenu = element as? UIMenu { revealImages(in: submenu) }
        }
    }
}
