// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum TerminalThemeAppearance: String, Codable, CaseIterable, Sendable {
    case light, dark, both

    public func includes(isDark: Bool) -> Bool {
        self == .both || self == (isDark ? .dark : .light)
    }
}

public nonisolated struct TerminalCustomTheme: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var appearance: TerminalThemeAppearance
    public var baseThemeName: String
    public var configuration: String

    public init(
        id: UUID = UUID(), name: String, appearance: TerminalThemeAppearance,
        baseThemeName: String, configuration: String = ""
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.baseThemeName = baseThemeName
        self.configuration = configuration
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !baseThemeName.isEmpty
    }

    public func copy(named name: String) -> Self {
        var copy = self
        copy.id = UUID()
        copy.name = name
        return copy
    }
}

/// The built-in name also remembers the fallback while a custom theme is selected.
public nonisolated struct TerminalThemeSelection: Codable, Hashable, Sendable {
    public var appearance: TerminalThemeAppearance
    public var builtInThemeName: String
    public var customThemeID: UUID?

    public init(appearance: TerminalThemeAppearance, builtInThemeName: String, customThemeID: UUID? = nil) {
        self.appearance = appearance
        self.builtInThemeName = builtInThemeName
        self.customThemeID = customThemeID
    }

    public var isValid: Bool { appearance != .both && !builtInThemeName.isEmpty }
}

public nonisolated struct TerminalThemeLibrary: Equatable, Sendable {
    public var themes: [TerminalCustomTheme]
    public var selections: [TerminalThemeSelection]

    public init(themes: [TerminalCustomTheme] = [], selections: [TerminalThemeSelection] = []) {
        self.themes = themes
        self.selections = selections
    }

    public func selection(isDark: Bool) -> TerminalThemeSelection? {
        selections.first { $0.appearance == (isDark ? .dark : .light) }
    }

    public func selectedTheme(isDark: Bool) -> TerminalCustomTheme? {
        guard let id = selection(isDark: isDark)?.customThemeID else { return nil }
        return themes.first { $0.id == id && $0.appearance.includes(isDark: isDark) }
    }

    public mutating func select(_ selection: TerminalThemeSelection) {
        selections.removeAll { $0.appearance == selection.appearance }
        selections.append(selection)
        selections.sort { $0.appearance.rawValue < $1.appearance.rawValue }
    }

    public mutating func repairSelections(for id: UUID) {
        for index in selections.indices where selections[index].customThemeID == id {
            let isDark = selections[index].appearance == .dark
            if !themes.contains(where: { $0.id == id && $0.appearance.includes(isDark: isDark) }) {
                selections[index].customThemeID = nil
            }
        }
    }
}
