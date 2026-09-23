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
            Toggle(TermindCopy.Settings.enableWebSearch.swiftUIKey, isOn: binding(\.isEnabled))

            Toggle(TermindCopy.Settings.preferBuiltInWebSearch.swiftUIKey, isOn: binding(\.prefersBuiltIn))
                .disabled(!isEnabled)

            Text(
                usesBuiltIn
                    ? String(
                        localized:
                            TermindCopy.Settings.nativeAndFallbackSearchExplanation
                    )
                    : String(
                        localized:
                            TermindCopy.Settings.webSearchExplanation
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(TermindCopy.Settings.webSearch)
        }

    }
}
