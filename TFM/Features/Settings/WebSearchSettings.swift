// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation

struct WebSearchSettings: View {
    @Environment(AppModel.self) private var app
    private var isEnabled: Bool { app.aiConfiguration.webSearch.isEnabled }
    private var usesBuiltIn: Bool { app.aiConfiguration.webSearch.prefersBuiltIn }
    private func binding(_ keyPath: WritableKeyPath<AIWebSearchPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { app.aiConfiguration.webSearch[keyPath: keyPath] },
            set: { value in
                var preferences = app.aiConfiguration.webSearch
                preferences[keyPath: keyPath] = value
                app.aiConfiguration.setWebSearch(preferences)
            })
    }

    var body: some View {
        Section {
            Toggle(AppStrings.Settings.enableWebSearch.swiftUIKey, isOn: binding(\.isEnabled))

            Toggle(AppStrings.Settings.preferBuiltInWebSearch.swiftUIKey, isOn: binding(\.prefersBuiltIn))
                .disabled(!isEnabled)

            Text(
                usesBuiltIn
                    ? AppStrings.Settings.nativeAndFallbackSearchExplanation
                    : AppStrings.Settings.webSearchExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(AppStrings.Settings.webSearch)
        }

    }
}
