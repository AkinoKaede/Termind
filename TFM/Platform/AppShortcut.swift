import AppKit
import SwiftUI

enum AppShortcutKey: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    case character(Character)
    case tab
    case escape
    case f3
    case rightArrow
    case downArrow

    init(extendedGraphemeClusterLiteral value: Character) { self = .character(value) }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let character): KeyEquivalent(character)
        case .tab: .tab
        case .escape: .escape
        case .f3: KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!))
        case .rightArrow: .rightArrow
        case .downArrow: .downArrow
        }
    }

    var appKitKeyEquivalent: String {
        switch self {
        case .character(let character): String(character)
        case .tab: "\t"
        case .escape: "\u{1B}"
        case .f3: String(Character(UnicodeScalar(NSF3FunctionKey)!))
        case .rightArrow: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .downArrow: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        }
    }
}

struct AppShortcutRegistration: Hashable, Sendable {
    let key: AppShortcutKey
    let modifiers: EventModifiers

    init(_ key: AppShortcutKey, modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.appKitModifiers == rhs.appKitModifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(appKitModifiers.rawValue)
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let significantModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        guard significantModifiers == appKitModifiers else { return false }

        switch key {
        case .tab: return event.keyCode == 48
        case .escape: return event.keyCode == 53
        // Key codes, like `.tab` above: the terminal has to recognise an arrow
        // and yield it before Ghostty encodes it as an escape sequence, and a
        // layout-independent comparison is the one that cannot miss.
        case .rightArrow: return event.keyCode == 124
        case .downArrow: return event.keyCode == 125
        case .f3:
            return event.charactersIgnoringModifiers?.unicodeScalars.first?.value
                == UInt32(NSF3FunctionKey)
        case .character(let character):
            let expected = String(character).lowercased()
            return event.characters(byApplyingModifiers: [])?.lowercased() == expected
                || event.charactersIgnoringModifiers?.lowercased() == expected
        }
    }
}

/// Stores declarations supplied by command definitions; it owns no concrete keys.
final class AppShortcutRegistry {
    enum TerminalRouting: Sendable {
        case application
        case terminal
    }

    static let shared = AppShortcutRegistry()
    private var applicationShortcuts: Set<AppShortcutRegistration> = []

    func register(
        _ shortcut: AppShortcutRegistration,
        terminalRouting: TerminalRouting = .application
    ) {
        guard terminalRouting == .application else { return }
        applicationShortcuts.insert(shortcut)
    }

    func routesToApplication(_ event: NSEvent) -> Bool {
        applicationShortcuts.contains { $0.matches(event) }
    }
}

extension View {
    func termindShortcut(
        _ key: AppShortcutKey,
        modifiers: EventModifiers = .command,
        terminalRouting: AppShortcutRegistry.TerminalRouting = .application
    ) -> some View {
        let shortcut = AppShortcutRegistration(key, modifiers: modifiers)
        AppShortcutRegistry.shared.register(shortcut, terminalRouting: terminalRouting)
        return keyboardShortcut(key.keyEquivalent, modifiers: modifiers)
    }
}

extension NSMenuItem {
    func setTermindShortcut(
        _ key: AppShortcutKey,
        modifiers: EventModifiers = .command,
        terminalRouting: AppShortcutRegistry.TerminalRouting = .application
    ) {
        let shortcut = AppShortcutRegistration(key, modifiers: modifiers)
        AppShortcutRegistry.shared.register(shortcut, terminalRouting: terminalRouting)
        keyEquivalent = key.appKitKeyEquivalent
        keyEquivalentModifierMask = shortcut.appKitModifiers
    }
}
