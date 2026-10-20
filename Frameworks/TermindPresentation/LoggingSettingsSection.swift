// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication

public struct LoggingSettingsSection: View {
    @Binding private var saving: Bool
    @Binding private var level: String

    public init(saving: Binding<Bool>, level: Binding<String>) {
        _saving = saving
        _level = level
    }

    public var body: some View {
        Section {
            Toggle(AppStrings.Common.save.swiftUIKey, isOn: $saving)
            Picker(AppStrings.Settings.level.swiftUIKey, selection: $level) {
                ForEach(ApplicationLogLevel.allCases) { level in
                    Text(verbatim: level.localizedName).tag(level.rawValue)
                }
            }
        } header: {
            Text(AppStrings.Settings.logging)
        } footer: {
            Text(AppStrings.Settings.logSharingWarning)
        }
    }
}
