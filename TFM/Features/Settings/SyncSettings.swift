import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct SyncSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var isEnabled = SettingsKey.defaultICloudSyncEnabled
    @AppStorage(SettingsKey.vaultSyncEnabled) private var includesVault = SettingsKey.defaultVaultSyncEnabled
    @AppStorage(SettingsKey.metricsSyncEnabled) private var includesMetrics = SettingsKey.defaultMetricsSyncEnabled
    @AppStorage(SettingsKey.settingsSyncEnabled) private var includesSettings = SettingsKey.defaultSettingsSyncEnabled
    private var isActive: Bool { isEnabled && app.proAccess.canUse(.vaultSync) }

    var body: some View {
        Section(TermindCopy.Keychain.iCloud.swiftUIKey) {
            Toggle(
                TermindCopy.Settings.iCloudSync.swiftUIKey,
                isOn: Binding(
                    get: { isActive },
                    set: { enabled in
                        guard !enabled || app.proAccess.require(.vaultSync) else { return }
                        isEnabled = enabled
                        if enabled {
                            do { try app.hostLibrary.migrateCustomPasswordsToICloud() } catch {
                                app.hostLibrary.reportStorageError(error)
                            }
                        }
                        app.reconcileProAccess()
                    })
            )
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                SyncSelectionRow(
                    title: TermindCopy.Navigation.vault,
                    isSelected: Binding(
                        get: { includesVault },
                        set: { value in
                            includesVault = value
                            if value {
                                do { try app.hostLibrary.migrateCustomPasswordsToICloud() } catch {
                                    app.hostLibrary.reportStorageError(error)
                                }
                            }
                            app.vaultSync?.setEnabled(value)
                        }), status: isActive ? app.vaultSync?.status : nil,
                    retry: { app.vaultSync?.retry() },
                    merge: { app.vaultSync?.confirmAccountSwitchMerge() })
                SyncSelectionRow(
                    title: TermindCopy.Navigation.metrics,
                    isSelected: Binding(
                        get: { includesMetrics },
                        set: { value in
                            includesMetrics = value
                            app.metricsSync?.setEnabled(value)
                        }), status: isActive ? app.metricsSync?.status : nil,
                    retry: { app.metricsSync?.retry() },
                    merge: { app.metricsSync?.confirmAccountSwitchMerge() })
                SyncSelectionRow(
                    title: TermindCopy.Navigation.settings,
                    isSelected: Binding(
                        get: { includesSettings },
                        set: { value in
                            includesSettings = value
                            app.settingsSync?.setEnabled(value)
                        }), status: isActive ? app.settingsSync?.status : nil,
                    retry: { app.settingsSync?.retry() },
                    merge: { app.settingsSync?.confirmAccountSwitchMerge() })
            }
            .disabled(!isActive)
        }
    }
}

private struct SyncSelectionRow: View {
    let title: LocalizedStringResource
    @Binding var isSelected: Bool
    let status: VaultSyncStatus?
    let retry: () -> Void
    let merge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            HStack {
                Toggle(isOn: $isSelected) {
                    Text(title)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if isSelected, let status {
                    VaultSyncStatusLabel(status: status)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isSelected, let status {
                switch status {
                case .accountChangeConfirmationRequired:
                    Button(TermindCopy.Settings.mergeWithThisICloudAccount.swiftUIKey, action: merge)
                case .failed, .partiallyBlocked:
                    // Retry fetches again; it never dismisses a persisted upload restriction.
                    Button(TermindCopy.Common.retry.swiftUIKey, action: retry)
                default: EmptyView()
                }
            }
        }
    }
}
