import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileSyncSettingsView: View {
    let app: MobileAppModel
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var enabled = SettingsKey.defaultICloudSyncEnabled
    @AppStorage(SettingsKey.vaultSyncEnabled) private var vault = SettingsKey.defaultVaultSyncEnabled
    @AppStorage(SettingsKey.metricsSyncEnabled) private var metrics = SettingsKey.defaultMetricsSyncEnabled
    @AppStorage(SettingsKey.settingsSyncEnabled) private var settings = SettingsKey.defaultSettingsSyncEnabled

    var body: some View {
        Form {
            Section {
                Toggle(
                    TermindCopy.Settings.iCloudSync.swiftUIKey,
                    isOn: selection(enabled && app.pro.canUse(.vaultSync), SettingsKey.iCloudSyncEnabled))
            }
            Section {
                Toggle(TermindCopy.Navigation.vault.swiftUIKey, isOn: selection(vault, SettingsKey.vaultSyncEnabled))
                if vault {
                    status(
                        app.vaultSync?.status, retry: { app.vaultSync?.retry() },
                        merge: { app.vaultSync?.confirmAccountSwitchMerge() })
                }
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
            Section {
                Toggle(
                    TermindCopy.Navigation.metrics.swiftUIKey, isOn: selection(metrics, SettingsKey.metricsSyncEnabled))
                if metrics {
                    status(
                        app.metricsSync?.status, retry: { app.metricsSync?.retry() },
                        merge: { app.metricsSync?.confirmAccountSwitchMerge() })
                }
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
            Section {
                Toggle(
                    TermindCopy.Navigation.settings.swiftUIKey,
                    isOn: selection(settings, SettingsKey.settingsSyncEnabled))
                if settings {
                    status(
                        app.settingsSync?.status, retry: { app.settingsSync?.retry() },
                        merge: { app.settingsSync?.confirmAccountSwitchMerge() })
                }
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
        }.navigationTitle(TermindCopy.Settings.sync.swiftUIKey)
    }

    private func selection(_ value: Bool, _ key: String) -> Binding<Bool> {
        Binding(get: { value }, set: { app.setSyncEnabled($0, key: key) })
    }

    @ViewBuilder
    private func status(_ value: VaultSyncStatus?, retry: @escaping () -> Void, merge: @escaping () -> Void)
        -> some View
    {
        if let value {
            VaultSyncStatusLabel(status: value)
            switch value {
            case .accountChangeConfirmationRequired:
                Button(TermindCopy.Settings.mergeWithThisICloudAccount.swiftUIKey, systemImage: "icloud", action: merge)
            case .failed, .partiallyBlocked:
                // Retry fetches again; it never dismisses a persisted upload restriction.
                Button(TermindCopy.Common.retry.swiftUIKey, systemImage: "arrow.clockwise", action: retry)
            default:
                EmptyView()
            }
        }
    }
}
