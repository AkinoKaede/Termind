import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite @MainActor
struct SettingsDetailControlTests {
    @Test func customConfigurationSwitchesPreserveIndependentTextAndPendingEdits() {
        let model = TerminalSettingsModel()
        #expect(model.set("background = ffffff", for: TerminalCustomConfigurationScheme.light.preferenceKeyPath))
        #expect(model.set("background = 000000", for: TerminalCustomConfigurationScheme.dark.preferenceKeyPath))
        #expect(model.set(true, for: TerminalCustomConfigurationScheme.light.enabledKeyPath))
        #expect(model.preferences.lightCustomEnabled)
        #expect(!model.preferences.darkCustomEnabled)
        // The editor's pending text arrives after its immediately persisted enable change.
        #expect(model.set(false, for: TerminalCustomConfigurationScheme.light.enabledKeyPath))
        #expect(model.set("background = eeeeee", for: TerminalCustomConfigurationScheme.light.preferenceKeyPath))
        #expect(!model.preferences.lightCustomEnabled)
        #expect(model.preferences.lightCustomConfiguration == "background = eeeeee")
        #expect(model.preferences.darkCustomConfiguration == "background = 000000")
        #expect(model.set(true, for: TerminalCustomConfigurationScheme.dark.enabledKeyPath))
        #expect(!model.preferences.lightCustomEnabled)
        #expect(model.preferences.darkCustomEnabled)
        #expect(model.preferences.lightCustomConfiguration == "background = eeeeee")
    }

    @Test func failedCustomConfigurationToggleRetainsPersistedStateAndText() {
        let model = TerminalSettingsModel(persistence: RejectingCustomConfigurationStore())
        #expect(!model.set(false, for: TerminalCustomConfigurationScheme.light.enabledKeyPath))
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
