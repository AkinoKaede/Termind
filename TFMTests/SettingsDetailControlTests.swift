import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import Termind

@Suite @MainActor
struct SettingsDetailControlTests {
    @Test func themeSelectionPreservesIndependentTextAndPendingEdits() {
        let model = TerminalSettingsModel()
        #expect(model.set("background = ffffff", for: \TerminalPreferences.lightCustomConfiguration))
        #expect(model.set("background = 000000", for: \TerminalPreferences.darkCustomConfiguration))
        #expect(model.selectCustomTheme(isDark: false))
        #expect(model.preferences.lightCustomEnabled)
        #expect(!model.preferences.darkCustomEnabled)
        // The editor's pending text arrives after selecting a preset.
        #expect(model.selectTheme(named: SettingsKey.defaultTerminalThemeLight, isDark: false))
        #expect(model.set("background = eeeeee", for: \TerminalPreferences.lightCustomConfiguration))
        #expect(!model.preferences.lightCustomEnabled)
        #expect(model.preferences.lightCustomConfiguration == "background = eeeeee")
        #expect(model.preferences.darkCustomConfiguration == "background = 000000")
        #expect(model.selectCustomTheme(isDark: true))
        #expect(!model.preferences.lightCustomEnabled)
        #expect(model.preferences.darkCustomEnabled)
        #expect(model.preferences.lightCustomConfiguration == "background = eeeeee")
    }

    @Test func failedPresetSelectionRetainsPersistedStateAndText() {
        let model = TerminalSettingsModel(persistence: RejectingCustomConfigurationStore())
        #expect(!model.selectTheme(named: SettingsKey.defaultTerminalThemeLight, isDark: false))
        #expect(model.preferences.lightCustomEnabled)
        #expect(model.preferences.lightCustomConfiguration == "background = ffffff")
        #expect(model.storageError != nil)
        var remote = model.preferences
        remote.lightCustomEnabled = false
        model.applyRemoteSnapshot(remote)
        #expect(!model.preferences.lightCustomEnabled)
        #expect(model.storageError == nil)
    }

}

@MainActor private final class RejectingCustomConfigurationStore: TerminalPreferencesPersisting {
    func loadTerminal() throws -> TerminalPreferences {
        var value = TerminalPreferences()
        value.lightCustomEnabled = true
        value.lightCustomConfiguration = "background = ffffff"
        return value
    }
    func saveTerminal(_ value: TerminalPreferences) throws { throw CocoaError(.fileWriteNoPermission) }
}
