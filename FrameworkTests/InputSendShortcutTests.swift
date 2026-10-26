// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

struct InputSendShortcutTests {
    @Test
    func defaultsToReturnAndRetainsTheChosenSendShortcut() throws {
        let name = "InputSendShortcutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(InputSendShortcut.stored(in: defaults) == .returnKey)
        defaults.set(InputSendShortcut.commandReturn.rawValue, forKey: SettingsKey.inputSendShortcut)
        #expect(InputSendShortcut.stored(in: try #require(UserDefaults(suiteName: name))) == .commandReturn)
        defaults.set("unknown", forKey: SettingsKey.inputSendShortcut)
        #expect(InputSendShortcut.stored(in: defaults) == .returnKey)
    }

    @Test(arguments: InputSendShortcut.allCases)
    func newlineIsTheImplicitInverseAndCompositionStaysWithTheSystem(shortcut: InputSendShortcut) {
        for command in [false, true] {
            #expect(
                shortcut.returnAction(command: command)
                    == (command == (shortcut == .commandReturn) ? .submit : .newline))
            #expect(shortcut.returnAction(command: command, shift: true) == .newline)
            #expect(shortcut.returnAction(command: command, control: true) == .system)
            #expect(shortcut.returnAction(command: command, option: true) == .system)
            #expect(shortcut.returnAction(command: command, hasMarkedText: true) == .system)
        }
    }
}
