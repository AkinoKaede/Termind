import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalExperiencePreferencesTests {
    @Test func missingKeysUseDefaultsAndExplicitFalseSurvivesRelaunch() throws {
        let domain = "TerminalExperience.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = TerminalExperienceSettingsModel(defaults: defaults)
        #expect(!model.preferences.bellSound)
        #expect(model.preferences.bellVibration)
        #expect(model.preferences.keepScreenAwake)

        model.set(true, for: \.bellSound)
        model.set(false, for: \.bellVibration)
        model.set(false, for: \.keepScreenAwake)
        let reopened = TerminalExperienceSettingsModel(defaults: defaults)
        #expect(reopened.preferences.bellSound)
        #expect(!reopened.preferences.bellVibration)
        #expect(!reopened.preferences.keepScreenAwake)
        #expect(TerminalExperienceSettingsModel().preferences == TerminalExperiencePreferences())
    }

    @Test func separateDevicesKeepIndependentChoices() throws {
        let firstDomain = "TerminalExperience.First.\(UUID())"
        let secondDomain = "TerminalExperience.Second.\(UUID())"
        let first = try #require(UserDefaults(suiteName: firstDomain))
        let second = try #require(UserDefaults(suiteName: secondDomain))
        defer {
            first.removePersistentDomain(forName: firstDomain)
            second.removePersistentDomain(forName: secondDomain)
        }
        let model = TerminalExperienceSettingsModel(defaults: first)
        model.set(true, for: \.bellSound)
        model.set(false, for: \.keepScreenAwake)
        #expect(TerminalExperienceSettingsModel(defaults: second).preferences == TerminalExperiencePreferences())
    }

    @Test func localChangesNeverEnterSettingsSyncAndRemoteSettingsCannotOverwriteThem() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "TerminalExperience.Sync.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let pending = try store.journal.pendingEnvelopes()
        let model = TerminalExperienceSettingsModel(defaults: defaults)
        model.set(true, for: \.bellSound)
        model.set(false, for: \.bellVibration)
        model.set(false, for: \.keepScreenAwake)
        #expect(try store.journal.pendingEnvelopes() == pending)

        let payload = SettingsRecordPayload.terminal(TerminalPreferences(lightTheme: "GitHub Light"))
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID(), now: .distantFuture), payload: payload)
        _ = try store.applyRemote([envelope])
        #expect(try store.loadTerminal().lightTheme == "GitHub Light")
        let reopened = TerminalExperienceSettingsModel(defaults: defaults)
        #expect(reopened.preferences.bellSound)
        #expect(!reopened.preferences.bellVibration)
        #expect(!reopened.preferences.keepScreenAwake)
    }
}
