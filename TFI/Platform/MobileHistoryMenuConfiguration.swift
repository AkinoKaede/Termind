import UIKit

/// Configure native History menus after SwiftUI has supplied their commands and images.
@MainActor
enum MobileHistoryMenuConfiguration {
    private static let recordImageIdentifier = "termind.history.connection"

    static func recordImage(systemName: String) -> UIImage {
        let image = (UIImage(systemName: systemName) ?? UIImage()).withRenderingMode(.alwaysTemplate)
        image.accessibilityIdentifier = recordImageIdentifier
        return image
    }

    static func apply(to builder: any UIMenuBuilder) {
        guard #available(iOS 17.4, *), builder.system === UIMenuSystem.main,
            let root = builder.menu(for: .root)
        else { return }
        for menu in root.children.compactMap({ $0 as? UIMenu }) where containsHistoryShortcut(menu) {
            builder.replace(menu: menu.identifier, with: configured(menu))
        }
    }

    // Identify the command independently of the app language and SwiftUI-generated menu identifiers.
    static func containsHistoryShortcut(_ menu: UIMenu) -> Bool {
        menu.children.contains { element in
            if isShowHistory(element) { return true }
            return (element as? UIMenu).map(containsHistoryShortcut) ?? false
        }
    }

    private static func isShowHistory(_ element: UIMenuElement) -> Bool {
        guard let command = element as? UIKeyCommand else { return false }
        return command.input?.lowercased() == "y" && command.modifierFlags == .command
    }

    static func configured(_ menu: UIMenu) -> UIMenu {
        guard #available(iOS 17.4, *) else { return menu }
        let children = menu.children.map { element -> UIMenuElement in
            if let submenu = element as? UIMenu { return configured(submenu) }
            if #available(iOS 27.0, *), element.image != nil,
                isShowHistory(element) || element.image?.accessibilityIdentifier == recordImageIdentifier
            {
                element.preferredImageVisibility = .visible
            }
            return element
        }
        let result = menu.replacingChildren(children)
        if #available(iOS 27.0, *), result.image?.accessibilityIdentifier == recordImageIdentifier {
            result.preferredImageVisibility = .visible
        }
        // Native menus own scrolling. Keep row heights stable when icon columns narrow nested menus.
        // Preferences apply only to immediate children, so each submenu needs its own copy.
        let preferences = UIMenuDisplayPreferences()
        preferences.maximumNumberOfTitleLines = 1
        result.displayPreferences = preferences
        return result
    }
}
