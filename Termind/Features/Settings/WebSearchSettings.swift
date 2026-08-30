import SwiftUI

struct WebSearchSettings: View {
    @AppStorage(SettingsKey.webSearchEnabled) private var isEnabled =
        SettingsKey.defaultWebSearchEnabled
    @AppStorage(SettingsKey.webSearchBuiltIn) private var usesBuiltIn =
        SettingsKey.defaultWebSearchBuiltIn

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: $isEnabled)

            Toggle("Prefer Built-in Web Search", isOn: $usesBuiltIn)
                .disabled(!isEnabled)

            Text(
                usesBuiltIn
                    ? String(
                        localized:
                            "Models with provider-native search use it directly. Other models search Google, Bing, DuckDuckGo, and Yahoo from this Mac and read result pages as Markdown."
                    )
                    : String(
                        localized:
                            "Every model searches Google, Bing, DuckDuckGo, and Yahoo from this Mac and reads result pages as Markdown."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Web Search")
        }

    }
}
