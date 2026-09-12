import SwiftUI
import TermindApplication
import TermindDomain

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
                    "iCloud Sync",
                    isOn: selection(enabled && app.pro.canUse(.vaultSync), SettingsKey.iCloudSyncEnabled))
            }
            Section {
                Toggle("Vault", isOn: selection(vault, SettingsKey.vaultSyncEnabled))
                if vault {
                    status(
                        app.vaultSync?.status, retry: { app.vaultSync?.retry() },
                        merge: { app.vaultSync?.confirmAccountSwitchMerge() })
                }
                Text("Hosts, identities, snippets, known hosts, and port forwards.").font(.caption).foregroundStyle(
                    .secondary)
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
            Section {
                Toggle("Metrics", isOn: selection(metrics, SettingsKey.metricsSyncEnabled))
                if metrics {
                    status(
                        app.metricsSync?.status, retry: { app.metricsSync?.retry() },
                        merge: { app.metricsSync?.confirmAccountSwitchMerge() })
                }
                Text("Monitored servers, pause state, device selections, and card order.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
            Section {
                Toggle("Settings", isOn: selection(settings, SettingsKey.settingsSyncEnabled))
                if settings {
                    status(
                        app.settingsSync?.status, retry: { app.settingsSync?.retry() },
                        merge: { app.settingsSync?.confirmAccountSwitchMerge() })
                }
                Text("Terminal and AI preferences.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
        }.navigationTitle("Sync")
    }

    private func selection(_ value: Bool, _ key: String) -> Binding<Bool> {
        Binding(get: { value }, set: { app.setSyncEnabled($0, key: key) })
    }

    @ViewBuilder
    private func status(_ value: VaultSyncStatus?, retry: @escaping () -> Void, merge: @escaping () -> Void)
        -> some View
    {
        if let value {
            switch value {
            case .checkingAccount: Label("Checking iCloud…", systemImage: "icloud")
            case .paused: Label("Paused", systemImage: "pause.circle")
            case .unavailable(let message): Text(message)
            case .accountChangeConfirmationRequired:
                Text("Waiting for confirmation")
                Button("Merge with This iCloud Account", systemImage: "icloud", action: merge)
            case .syncing(let count): Text("Syncing \(count) changes…")
            case .upToDate(let date):
                HStack {
                    Label("Up to date", systemImage: "checkmark.icloud")
                    Spacer(minLength: 8)
                    if let date {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
            }
        }
    }
}
