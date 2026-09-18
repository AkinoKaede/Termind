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
        Section("iCloud") {
            Toggle(
                "iCloud Sync",
                isOn: Binding(
                    get: { isActive },
                    set: { enabled in
                        guard !enabled || app.proAccess.require(.vaultSync) else { return }
                        isEnabled = enabled
                        app.reconcileProAccess()
                    })
            )
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                SyncSelectionRow(
                    title: "Vault", detail: "Hosts, identities, snippets, known hosts, and port forwards.",
                    isSelected: Binding(
                        get: { includesVault },
                        set: { value in
                            includesVault = value
                            app.vaultSync?.setEnabled(value)
                        }), status: isActive ? app.vaultSync?.status : nil,
                    retry: { app.vaultSync?.retry() },
                    merge: { app.vaultSync?.confirmAccountSwitchMerge() })
                SyncSelectionRow(
                    title: "Metrics", detail: "Monitored servers, pause state, device selections, and card order.",
                    isSelected: Binding(
                        get: { includesMetrics },
                        set: { value in
                            includesMetrics = value
                            app.metricsSync?.setEnabled(value)
                        }), status: isActive ? app.metricsSync?.status : nil,
                    retry: { app.metricsSync?.retry() },
                    merge: { app.metricsSync?.confirmAccountSwitchMerge() })
                SyncSelectionRow(
                    title: "Settings", detail: "Terminal, SFTP, and AI preferences.",
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var isSelected: Bool
    let status: VaultSyncStatus?
    let retry: () -> Void
    let merge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            HStack {
                Toggle(isOn: $isSelected) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text(title)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
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
                    Button("Merge with This iCloud Account", action: merge)
                case .failed:
                    Button("Retry", action: retry)
                default: EmptyView()
                }
            }
        }
    }
}
