// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileSyncSettingsView: View {
    let app: MobileAppModel
    @AppStorage(SettingsKey.iCloudSyncEnabled) private var enabled = SettingsKey.defaultICloudSyncEnabled
    @AppStorage(SettingsKey.historySyncEnabled) private var history = SettingsKey.defaultHistorySyncEnabled
    @AppStorage(SettingsKey.metricsSyncEnabled) private var metrics = SettingsKey.defaultMetricsSyncEnabled
    @AppStorage(SettingsKey.settingsSyncEnabled) private var settings = SettingsKey.defaultSettingsSyncEnabled

    var body: some View {
        Form {
            CloudSyncSettingsContent(
                enabled: selection(enabled && app.pro.canUse(.vaultSync), SettingsKey.iCloudSyncEnabled),
                history: selection(history, SettingsKey.historySyncEnabled),
                settings: selection(settings, SettingsKey.settingsSyncEnabled),
                metrics: selection(metrics, SettingsKey.metricsSyncEnabled), categories: syncCategories)
        }.navigationTitle(AppStrings.Settings.sync.swiftUIKey)
    }

    private func selection(_ value: Bool, _ key: String) -> Binding<Bool> {
        Binding(get: { value }, set: { app.setSyncEnabled($0, key: key) })
    }

    private var syncCategories: [CloudSyncCategoryPresentation] {
        [
            .init(
                id: "vault", status: app.vaultSync?.status,
                retry: { app.vaultSync?.retry() }, merge: { app.vaultSync?.confirmAccountSwitchMerge() }),
            .init(
                id: "history", isSelected: history,
                status: app.connectionHistorySync?.status, retry: { app.connectionHistorySync?.retry() },
                merge: { app.connectionHistorySync?.confirmAccountSwitchMerge() }),
            .init(
                id: "devices",
                status: app.deviceSync?.status,
                retry: { app.deviceSync?.retry() }, merge: { app.deviceSync?.confirmAccountSwitchMerge() }),
            .init(
                id: "metrics", isSelected: metrics,
                status: app.metricsSync?.status, retry: { app.metricsSync?.retry() },
                merge: { app.metricsSync?.confirmAccountSwitchMerge() }),
            .init(
                id: "settings", isSelected: settings,
                status: app.settingsSync?.status, retry: { app.settingsSync?.retry() },
                merge: { app.settingsSync?.confirmAccountSwitchMerge() }),
        ]
    }
}
