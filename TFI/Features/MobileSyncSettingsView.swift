import SwiftUI
import TermindApplication
import TermindDomain

struct MobileSyncSettingsView: View {
    let app: MobileAppModel
    @AppStorage(SharedSettingsKey.iCloudSyncEnabled) private var enabled = true
    @AppStorage(SharedSettingsKey.vaultSyncEnabled) private var vault = true
    @AppStorage(SharedSettingsKey.settingsSyncEnabled) private var settings = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "iCloud Sync",
                    isOn: selection(enabled && app.pro.canUse(.vaultSync), SharedSettingsKey.iCloudSyncEnabled))
            }
            Section {
                Toggle("Vault", isOn: selection(vault, SharedSettingsKey.vaultSyncEnabled))
                if vault {
                    status(
                        app.vaultSync?.status, retry: { app.vaultSync?.retry() },
                        merge: { app.vaultSync?.confirmAccountSwitchMerge() })
                }
                Text("Hosts, identities, snippets, known hosts, and port forwards.").font(.caption).foregroundStyle(
                    .secondary)
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
            Section {
                Toggle("Settings", isOn: selection(settings, SharedSettingsKey.settingsSyncEnabled))
                if settings {
                    status(
                        app.settingsSync?.status, retry: { app.settingsSync?.retry() },
                        merge: { app.settingsSync?.confirmAccountSwitchMerge() })
                }
                Text("Terminal and AI preferences.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!enabled || !app.pro.canUse(.vaultSync))
            if settings {
                Text("API keys use iCloud Keychain, even when configuration sync is paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
