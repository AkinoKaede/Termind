// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

public struct SSHSettingsFields: View {
    let model: SSHSettingsModel

    public init(model: SSHSettingsModel) { self.model = model }

    public var body: some View {
        Stepper(value: binding(\.maxSessions), in: SSHPreferences.maxSessionsRange) {
            HStack {
                Text("Max Sessions")
                Spacer()
                Text(model.preferences.maxSessions, format: .number).monospacedDigit()
            }
        }
        Text(AppStrings.Settings.sshMaxSessionsExplanation)
            .font(.caption).foregroundStyle(.secondary)
        if let error = model.storageError { Text(error).foregroundStyle(.red) }
    }

    private func binding(_ keyPath: WritableKeyPath<SSHPreferences, Int>) -> Binding<Int> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { model.set($0, for: keyPath) })
    }
}
