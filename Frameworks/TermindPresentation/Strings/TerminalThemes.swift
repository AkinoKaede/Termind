// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings.Settings {
    public static var customThemes: LocalizedStringResource { "Custom Themes" }
    public static var newCustomTheme: LocalizedStringResource { "New Custom Theme" }
    public static var builtInThemes: LocalizedStringResource { "Built-in Themes" }
    public static var themeLight: LocalizedStringResource { "Light" }
    public static var themeDark: LocalizedStringResource { "Dark" }
    public static var themeBoth: LocalizedStringResource { "Both" }
    public static var noCustomThemes: LocalizedStringResource { "Create a custom theme to get started." }
    public static var themePreviewCursor: LocalizedStringResource { "Cursor" }
    public static var themePreviewSelection: LocalizedStringResource { "Selected text" }
    public static var themePreviewPalette: LocalizedStringResource { "ANSI Palette" }
    public static var deleteCustomThemeConfirmation: LocalizedStringResource {
        "Delete this custom theme?"
    }
    public static var deleteCustomThemeWarning: LocalizedStringResource {
        "Appearances using it will return to their previous built-in theme."
    }
    public static var discardNewCustomThemeQuestion: LocalizedStringResource {
        "Are you sure you want to discard this new custom theme?"
    }
    public static var customThemeDeleted: LocalizedStringResource {
        "This theme was deleted on another device. You can save your changes as a new theme."
    }
    public static var saveThemeCopy: LocalizedStringResource { "Save as New Theme" }
    public static func customThemeCopy(_ name: String) -> LocalizedStringResource { "\(name) Copy" }
}
