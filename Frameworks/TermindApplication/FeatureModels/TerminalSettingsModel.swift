import Foundation
import TermindDomain

/// Settings edits persist first, then update every window and the terminal runtime.
@Observable
public final class TerminalSettingsModel {
    public private(set) var preferences = TerminalPreferences()
    public private(set) var themeLibrary = TerminalThemeLibrary()
    public private(set) var storageError: String?
    private let persistence: (any TerminalPreferencesPersisting)?

    public init(persistence: (any TerminalPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do {
            if let persistence {
                preferences = try persistence.loadTerminal()
                themeLibrary = try persistence.loadTerminalThemes()
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func set<Value>(_ value: Value, for keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Bool {
        var next = preferences
        next[keyPath: keyPath] = value
        return save(next)
    }

    /// A theme choice is one persisted edit, including disabling the custom overlay.
    @discardableResult
    public func selectTheme(named name: String, isDark: Bool) -> Bool {
        if persistence?.usesNativeTerminalThemes == true || !themeLibrary.selections.isEmpty {
            var next = themeLibrary
            next.select(.init(appearance: isDark ? .dark : .light, builtInThemeName: name))
            return saveLibrary(next)
        }
        var next = preferences
        if isDark {
            next.darkTheme = name
            next.darkCustomEnabled = false
        } else {
            next.lightTheme = name
            next.lightCustomEnabled = false
        }
        return save(next)
    }

    @discardableResult
    public func selectCustomTheme(isDark: Bool) -> Bool {
        set(true, for: isDark ? \.darkCustomEnabled : \.lightCustomEnabled)
    }

    private func save(_ next: TerminalPreferences) -> Bool {
        guard next != preferences else { return true }
        do {
            try persistence?.saveTerminal(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: TerminalPreferences) {
        preferences = value
        storageError = nil
    }

    public func applyRemoteThemes(_ value: TerminalThemeLibrary) {
        themeLibrary = value
        storageError = nil
    }

    @discardableResult
    public func saveCustomTheme(_ value: TerminalCustomTheme, isNew: Bool) -> Bool {
        guard value.isValid, isNew != themeLibrary.themes.contains(where: { $0.id == value.id }) else { return false }
        var next = themeLibrary
        next.themes.removeAll { $0.id == value.id }
        next.themes.append(value)
        next.repairSelections(for: value.id)
        return saveLibrary(next)
    }

    @discardableResult
    public func deleteCustomTheme(id: UUID) -> Bool {
        var next = themeLibrary
        next.themes.removeAll { $0.id == id }
        next.repairSelections(for: id)
        return saveLibrary(next)
    }

    @discardableResult
    public func selectCustomTheme(id: UUID, isDark: Bool) -> Bool {
        guard themeLibrary.themes.contains(where: { $0.id == id && $0.appearance.includes(isDark: isDark) }) else {
            return false
        }
        var next = themeLibrary
        let legacyBase = isDark ? preferences.darkTheme : preferences.lightTheme
        var selection =
            next.selection(isDark: isDark)
            ?? .init(
                appearance: isDark ? .dark : .light,
                builtInThemeName: legacyBase.isEmpty ? (isDark ? "Termind Dark" : "Termind Light") : legacyBase)
        selection.customThemeID = id
        next.select(selection)
        return saveLibrary(next)
    }

    private func saveLibrary(_ value: TerminalThemeLibrary) -> Bool {
        guard value != themeLibrary else { return true }
        do {
            try persistence?.saveTerminalThemes(value)
            applyRemoteThemes(value)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }
}
