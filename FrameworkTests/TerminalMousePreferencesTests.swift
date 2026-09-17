import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalMousePreferencesTests {
    @Test func mousePreferencesDefaultOffAndChangeIndependently() {
        let model = TerminalSettingsModel()
        #expect(!model.preferences.copyOnSelect)
        #expect(!model.preferences.pasteOnRightClick)
        #expect(model.set(true, for: \.copyOnSelect))
        #expect(model.preferences.copyOnSelect)
        #expect(!model.preferences.pasteOnRightClick)
        #expect(model.set(true, for: \.pasteOnRightClick))
        #expect(model.set(false, for: \.copyOnSelect))
        #expect(!model.preferences.copyOnSelect)
        #expect(model.preferences.pasteOnRightClick)
    }

    @Test func oldLocalBlobsAndSyncPayloadsDecodeWithMousePreferencesOff() throws {
        let data = Data(
            #"{"fontSize":18,"fontFollowTheme":false,"darkTheme":"Termind Dark","lightTheme":"Termind Light","darkCustomEnabled":true,"lightCustomEnabled":false,"darkCustomConfiguration":"background = 112233","lightCustomConfiguration":"","shellIntegration":false,"remoteWindowTitleInMenuBar":false}"#
                .utf8)
        let row = try PersistentTerminalPreferences(.init(copyOnSelect: true, pasteOnRightClick: true))
        row.data = data
        let value = try row.load()
        #expect(!value.copyOnSelect)
        #expect(!value.pasteOnRightClick)
        #expect(value.fontSize == 18)
        #expect(value.darkCustomConfiguration == "background = 112233")
        #expect(!value.shellIntegration)

        let payload = Data(#"{"terminal":{"_0": "#.utf8) + data + Data("}}".utf8)
        #expect(try JSONDecoder().decode(SettingsRecordPayload.self, from: payload) == .terminal(value))
    }

    @Test func mousePreferencesRoundTripAndMirrorWithoutLosingOtherSettings() throws {
        let domain = "TerminalMousePreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let original = TerminalPreferences(fontSize: 17, copyOnSelect: true, pasteOnRightClick: true)
        let row = try PersistentTerminalPreferences(original)
        #expect(try row.load() == original)
        original.mirror(to: defaults)
        #expect(defaults.bool(forKey: SettingsKey.terminalCopyOnSelect))
        #expect(defaults.bool(forKey: SettingsKey.terminalPasteOnRightClick))
        #expect(TerminalPreferences(defaults: defaults) == original)
    }

    @Test func mobileStyleTerminalEditPreservesSyncedDesktopMousePreferences() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "TerminalMouseMobileEdit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let preferences = TerminalPreferences(copyOnSelect: true, pasteOnRightClick: true)
        let payload = SettingsRecordPayload.terminal(preferences)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID(), now: .now), payload: payload)
        let snapshot = try store.applyRemote([envelope]).snapshot
        let model = TerminalSettingsModel(persistence: store)
        model.applyRemoteSnapshot(snapshot.terminal)
        #expect(model.set(20, for: \.fontSize))
        let saved = try store.loadTerminal()
        #expect(saved.fontSize == 20)
        #expect(saved.copyOnSelect)
        #expect(saved.pasteOnRightClick)
        let pending = try #require(try store.journal.pendingEnvelopes().first { $0.key.kind == .terminal })
        #expect(pending.payload == .terminal(saved))
    }
}
