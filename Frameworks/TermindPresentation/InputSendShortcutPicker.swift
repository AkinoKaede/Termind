// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication

public struct InputSendShortcutPicker: View {
    @AppStorage(SettingsKey.inputSendShortcut) private var shortcut = InputSendShortcut.returnKey

    public init() {}

    public var body: some View {
        Picker(AppStrings.Assistant.send.swiftUIKey, selection: $shortcut) {
            Text(AppStrings.Settings.returnKey).tag(InputSendShortcut.returnKey)
            Text(AppStrings.Settings.commandReturn).tag(InputSendShortcut.commandReturn)
        }
        .pickerStyle(.menu)
    }
}
