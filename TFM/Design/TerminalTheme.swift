import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct ResolvedTerminalAppearance: Equatable {
    var preferences: TerminalPreferences
    var font: TerminalFontPreferences
    var library: TerminalThemeLibrary
}

/// The live terminal appearance selected in Settings.
///
/// Only settings changes reconfigure the surface. Its live background is observed separately.
@propertyWrapper
struct TerminalAppearanceSettings: DynamicProperty {
    @Environment(AppModel.self) private var app
    @TerminalFontSettings private var font

    var wrappedValue: ResolvedTerminalAppearance {
        return ResolvedTerminalAppearance(
            preferences: app.terminalSettings.preferences,
            font: font.resolvingFamily(in: TerminalFontCatalog.shared.families),
            library: app.terminalSettings.themeLibrary
        )
    }
}
