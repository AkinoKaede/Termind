import SwiftUI
import TermindApplication

struct MobileAppSettingsView: View {
    var appReview: AppReviewController?
    var reviewScene: MobileSceneModel?
    @AppStorage("mobile.appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Follow System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
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
