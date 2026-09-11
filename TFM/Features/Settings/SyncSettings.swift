import SwiftUI
import TermindApplication
import TermindDomain

struct SyncSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var isEnabled = SettingsKey.defaultICloudSyncEnabled
    @AppStorage(SettingsKey.vaultSyncEnabled) private var includesVault = SettingsKey.defaultVaultSyncEnabled
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
                    title: "Settings", detail: "Terminal and AI preferences.",
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

            if includesSettings {
                Text("API keys use iCloud Keychain, even when configuration sync is paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    SyncStatusLabel(status: status)
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

struct SyncStatusLabel: View {
    let status: VaultSyncStatus
    @Environment(\.locale) private var locale

    @ViewBuilder
    var body: some View {
        switch status {
        case .checkingAccount:
            Label("Checking iCloud…", systemImage: "icloud")
        case .paused:
            Label("Paused", systemImage: "pause.circle")
        case .unavailable(let message):
            Label(message, systemImage: "icloud.slash").foregroundStyle(.secondary)
        case .accountChangeConfirmationRequired:
            Label("Waiting for confirmation", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .syncing(let pendingCount):
            Label(
                pendingCount == 1 ? "Syncing 1 change…" : "Syncing \(pendingCount) changes…",
                systemImage: "arrow.triangle.2.circlepath.icloud"
            )
        case .upToDate(let lastSync):
            if let lastSync {
                let formatted = lastSync.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
                )
                Label(
                    "Up to date · \(formatted)",
                    systemImage: "checkmark.icloud"
                )
            } else {
                Label("Up to date", systemImage: "checkmark.icloud")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }
}
