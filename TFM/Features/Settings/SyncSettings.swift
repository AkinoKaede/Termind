import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct SyncSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var isEnabled = SettingsKey.defaultICloudSyncEnabled
    @AppStorage(SettingsKey.historySyncEnabled) private var includesHistory = SettingsKey.defaultHistorySyncEnabled
    @AppStorage(SettingsKey.metricsSyncEnabled) private var includesMetrics = SettingsKey.defaultMetricsSyncEnabled
    @AppStorage(SettingsKey.settingsSyncEnabled) private var includesSettings = SettingsKey.defaultSettingsSyncEnabled
    private var isActive: Bool { isEnabled && app.proAccess.canUse(.vaultSync) }

    var body: some View {
        CloudSyncSettingsContent(
            enabled: Binding(
                get: { isActive },
                set: { enabled in
                    guard !enabled || app.proAccess.require(.vaultSync) else { return }
                    isEnabled = enabled
                    if enabled { migratePasswords() }
                    app.reconcileProAccess()
                }),
            history: Binding(
                get: { includesHistory },
                set: {
                    includesHistory = $0
                    app.connectionHistorySync?.setEnabled($0)
                }),
            settings: Binding(
                get: { includesSettings },
                set: {
                    includesSettings = $0
                    app.settingsSync?.setEnabled($0)
                }),
            metrics: Binding(
                get: { includesMetrics },
                set: {
                    includesMetrics = $0
                    app.metricsSync?.setEnabled($0)
                }), categories: syncCategories)
    }

    private func migratePasswords() {
        do { try app.hostLibrary.migrateCustomPasswordsToICloud() } catch { app.hostLibrary.reportStorageError(error) }
    }

    private var syncCategories: [CloudSyncCategoryPresentation] {
        [
            .init(
                id: "vault", title: AppStrings.Navigation.vault, status: app.vaultSync?.status,
                retry: { app.vaultSync?.retry() }, merge: { app.vaultSync?.confirmAccountSwitchMerge() }),
            .init(
                id: "history", title: AppStrings.Common.history, isSelected: includesHistory,
                status: app.connectionHistorySync?.status, retry: { app.connectionHistorySync?.retry() },
                merge: { app.connectionHistorySync?.confirmAccountSwitchMerge() }),
            .init(
                id: "devices", title: AppStrings.Settings.devices,
                status: app.deviceSync?.status,
                retry: { app.deviceSync?.retry() }, merge: { app.deviceSync?.confirmAccountSwitchMerge() }),
            .init(
                id: "metrics", title: AppStrings.Navigation.metrics, isSelected: includesMetrics,
                status: app.metricsSync?.status, retry: { app.metricsSync?.retry() },
                merge: { app.metricsSync?.confirmAccountSwitchMerge() }),
            .init(
                id: "settings", title: AppStrings.Navigation.settings, isSelected: includesSettings,
                status: app.settingsSync?.status, retry: { app.settingsSync?.retry() },
                merge: { app.settingsSync?.confirmAccountSwitchMerge() }),
        ]
    }
}
