// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct TerminalThemeSelectionTests {
    @Test(arguments: [false, true])
    func presetSelectionPersistsNameAndDisablesCustomInOneWrite(isDark: Bool) {
        let initial = TerminalPreferences(
            darkCustomEnabled: true, lightCustomEnabled: true,
            darkCustomConfiguration: "background = 010203", lightCustomConfiguration: "foreground = 112233")
        let store = ThemeStore(initial)
        let model = TerminalSettingsModel(persistence: store)
        #expect(model.selectTheme(named: "Chosen Theme", isDark: isDark))
        var expected = initial
        if isDark {
            expected.darkTheme = "Chosen Theme"
            expected.darkCustomEnabled = false
        } else {
            expected.lightTheme = "Chosen Theme"
            expected.lightCustomEnabled = false
        }
        #expect(store.saved == [expected])
        #expect(model.preferences == expected)
        #expect(model.selectCustomTheme(isDark: isDark))
        #expect(model.preferences.darkCustomEnabled)
        #expect(model.preferences.lightCustomEnabled)
        #expect(model.preferences.darkCustomConfiguration == initial.darkCustomConfiguration)
        #expect(model.preferences.lightCustomConfiguration == initial.lightCustomConfiguration)
        #expect((isDark ? model.preferences.darkTheme : model.preferences.lightTheme) == "Chosen Theme")
        #expect(store.saved.count == 2)
        #expect(model.selectCustomTheme(isDark: isDark))
        #expect(store.saved.count == 2)
    }

    @Test(arguments: [false, true])
    func failedSelectionKeepsBothFieldsAndCanBeRetried(isDark: Bool) {
        let initial = TerminalPreferences(darkCustomEnabled: true, lightCustomEnabled: true)
        let store = ThemeStore(initial)
        store.fails = true
        let model = TerminalSettingsModel(persistence: store)
        #expect(!model.selectTheme(named: "New Theme", isDark: isDark))
        #expect(model.preferences == initial)
        #expect(model.storageError != nil)
        store.fails = false
        #expect(model.selectTheme(named: "New Theme", isDark: isDark))
        #expect(model.storageError == nil)
        #expect(store.saved.count == 1)
    }

    @Test func openingAndApplyingRemoteCustomSelectionNeverWrites() {
        let initial = TerminalPreferences(darkTheme: "Missing", darkCustomEnabled: true)
        let store = ThemeStore(initial)
        let model = TerminalSettingsModel(persistence: store)
        #expect(model.preferences == initial)
        model.applyRemoteSnapshot(TerminalPreferences(lightCustomEnabled: true))
        #expect(model.preferences.lightCustomEnabled)
        #expect(store.saved.isEmpty)
    }
}

@MainActor private final class ThemeStore: TerminalPreferencesPersisting {
    let initial: TerminalPreferences
    var saved: [TerminalPreferences] = []
    var fails = false
    init(_ initial: TerminalPreferences) { self.initial = initial }
    func loadTerminal() throws -> TerminalPreferences { initial }
    func saveTerminal(_ value: TerminalPreferences) throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        saved.append(value)
    }
}
