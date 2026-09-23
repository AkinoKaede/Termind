import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileAppSettingsView: View {
    let workspaceSettings: WorkspaceSettingsModel
    var appReview: AppReviewController?
    var reviewScene: MobileSceneModel?
    @AppStorage("mobile.appearance") private var appearance = "system"
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false

    var body: some View {
        Form {
            Section(TermindCopy.Settings.appearance.swiftUIKey) {
                Picker(TermindCopy.Settings.theme.swiftUIKey, selection: $appearance) {
                    Text(TermindCopy.Settings.followSystem).tag("system")
                    Text(TermindCopy.Settings.light).tag("light")
                    Text(TermindCopy.Settings.dark).tag("dark")
                }
            }
            Section {
                Toggle(
                    TermindCopy.Settings.automaticallyRenameWorkspaces.swiftUIKey,
                    isOn: Binding(
                        get: { workspaceSettings.preferences.automaticallyRenamesWorkspaces },
                        set: { _ = workspaceSettings.setAutomaticRenaming($0) }
                    )
                )
                if let error = workspaceSettings.storageError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text(TermindCopy.Navigation.workspaces)
            } footer: {
                Text(TermindCopy.Settings.workspaceNumberingExplanation)
            }
            Section(TermindCopy.Settings.version.swiftUIKey) {
                LabeledContent(
                    TermindCopy.Settings.app.swiftUIKey,
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 3) { debugSectionEnabled.toggle() }
                LabeledContent(TermindCopy.Settings.ghostty.swiftUIKey, value: MobileRuntimeVersions.ghostty)
                LabeledContent(TermindCopy.Settings.libssh2.swiftUIKey, value: MobileRuntimeVersions.libssh2)
                LabeledContent(TermindCopy.Settings.openSSL.swiftUIKey, value: MobileRuntimeVersions.openSSL)
            }
            Section(TermindCopy.Settings.support.swiftUIKey) {
                Link(destination: AppReviewController.reviewURL) {
                    Label(TermindCopy.Settings.rateOnTheAppStore.swiftUIKey, systemImage: "star")
                }
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        appReview?.recordManualReview()
                        return .systemAction(url)
                    }
                )
                Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                    Label(TermindCopy.Settings.support.swiftUIKey, systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                    Label(TermindCopy.Pro.privacyPolicy.swiftUIKey, systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle(TermindCopy.Settings.app.swiftUIKey)
        .mobileReviewPage("settings.app", scene: reviewScene)
    }
}
