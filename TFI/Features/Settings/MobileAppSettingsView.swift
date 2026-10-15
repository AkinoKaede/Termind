import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileAppSettingsView: View {
    let workspaceSettings: WorkspaceSettingsModel
    var appReview: AppReviewController?
    var diagnosis = DiagnosisController()
    @AppStorage("mobile.appearance") private var appearance = "system"
    @AppStorage("mobile.compactCards") private var compactCards = false
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false

    var body: some View {
        Form {
            Section(AppStrings.Settings.appearance.swiftUIKey) {
                Picker(AppStrings.Settings.theme.swiftUIKey, selection: $appearance) {
                    Text(AppStrings.Settings.followSystem).tag("system")
                    Text(AppStrings.Settings.light).tag("light")
                    Text(AppStrings.Settings.dark).tag("dark")
                }
                Toggle(AppStrings.Settings.compactCards.swiftUIKey, isOn: $compactCards)
            }
            Section {
                Toggle(
                    AppStrings.Settings.automaticallyRenameWorkspaces.swiftUIKey,
                    isOn: Binding(
                        get: { workspaceSettings.preferences.automaticallyRenamesWorkspaces },
                        set: { _ = workspaceSettings.setAutomaticRenaming($0) }
                    )
                )
                if let error = workspaceSettings.storageError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text(AppStrings.Navigation.workspaces)
            } footer: {
                Text(AppStrings.Settings.workspaceNumberingExplanation)
            }
            DiagnosisSettingsSection(controller: diagnosis)
            Section(AppStrings.Settings.version.swiftUIKey) {
                LabeledContent(
                    AppStrings.Settings.app.swiftUIKey,
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 3) { debugSectionEnabled.toggle() }
                LabeledContent(AppStrings.Settings.ghostty.swiftUIKey, value: MobileRuntimeVersions.ghostty)
                LabeledContent(AppStrings.Settings.libssh2.swiftUIKey, value: MobileRuntimeVersions.libssh2)
                LabeledContent(AppStrings.Settings.openSSL.swiftUIKey, value: MobileRuntimeVersions.openSSL)
                LabeledContent(AppStrings.Tailscale.title.swiftUIKey, value: MobileRuntimeVersions.tailscale)
            }
            Section(AppStrings.Settings.support.swiftUIKey) {
                AppReviewLink(controller: appReview) {
                    Label(AppStrings.Settings.rateOnTheAppStore.swiftUIKey, systemImage: "star")
                }
                Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                    Label(AppStrings.Settings.support.swiftUIKey, systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                    Label(AppStrings.Pro.privacyPolicy.swiftUIKey, systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle(AppStrings.Settings.app.swiftUIKey)
    }
}
