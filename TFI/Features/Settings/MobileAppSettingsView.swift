import SwiftUI
import TermindApplication

struct MobileAppSettingsView: View {
    var appReview: AppReviewController?
    var reviewScene: MobileSceneModel?
    @AppStorage("mobile.appearance") private var appearance = "system"
    @AppStorage(SettingsKey.appLanguage) private var language = AppLanguage.system.rawValue
    @State private var launchLanguage = AppLanguage.stored()

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? AppLanguage.stored()
    }

    private var languageSelection: Binding<AppLanguage> {
        Binding(
            get: { selectedLanguage },
            set: { language in
                self.language = language.rawValue
                AppLanguage.store(language)
            })
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Follow System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Language", selection: languageSelection) {
                    ForEach(AppLanguage.allCases) {
                        Text(
                            $0.displayName(
                                deviceRegion: Locale.autoupdatingCurrent.region?.identifier,
                                canDisplayTaiwanFlag: DeviceCensorship.canDisplayTaiwanFlag
                            )
                        ).tag($0)
                    }
                }
                if selectedLanguage != launchLanguage {
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
                Link(destination: AppReviewController.reviewURL) {
                    Label("Rate on the App Store", systemImage: "star")
                }
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        appReview?.recordManualReview()
                        return .systemAction(url)
                    }
                )
                Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle("App")
        .mobileReviewPage("settings.app", scene: reviewScene)
    }
}
