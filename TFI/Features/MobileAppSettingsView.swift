import SwiftUI
import TermindApplication

struct MobileAppSettingsView: View {
    @AppStorage("mobile.appearance") private var appearance = "system"
    @AppStorage(SharedSettingsKey.appLanguage) private var language = AppLanguage.system.rawValue
    @State private var launchLanguage = AppLanguage.stored()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Follow System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if language != launchLanguage.rawValue {
                    Text("The new language will be used after Termind relaunches.").font(.caption).foregroundStyle(
                        .secondary)
                }
            }
            Section("Version") {
                LabeledContent(
                    "App",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                LabeledContent("Ghostty", value: MobileRuntimeVersions.ghostty)
                LabeledContent("libssh2", value: MobileRuntimeVersions.libssh2)
                LabeledContent("OpenSSL", value: MobileRuntimeVersions.openSSL)
            }
            Section("Support") {
                Link(destination: URL(string: "https://apps.apple.com/app/id6805856690?action=write-review")!) {
                    Label("Rate on the App Store", systemImage: "star")
                }
                Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle("App")
        .onChange(of: language) { _, value in AppLanguage.store(AppLanguage(rawValue: value) ?? .system) }
    }
}
