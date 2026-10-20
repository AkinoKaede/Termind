// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Shared section ownership keeps macOS and iOS copy, order and disabled states
/// identical. Apps inject bindings so account/pro eligibility and engine lifetimes
/// stay with their composition root; Presentation never starts synchronization.
public struct CloudSyncSettingsContent: View {
    @Binding private var enabled: Bool
    @Binding private var history: Bool
    @Binding private var settings: Bool
    @Binding private var metrics: Bool
    private let categories: [CloudSyncCategoryPresentation]

    public init(
        enabled: Binding<Bool>, history: Binding<Bool>,
        settings: Binding<Bool>, metrics: Binding<Bool>, categories: [CloudSyncCategoryPresentation]
    ) {
        _enabled = enabled
        _history = history
        _settings = settings
        _metrics = metrics
        self.categories = categories
    }

    public var body: some View {
        Section {
            Toggle(AppStrings.Settings.iCloudSync.swiftUIKey, isOn: $enabled)
                .toggleStyle(.switch)
            CloudSyncSummaryView(categories: categories, isActive: enabled)
        }
        Section(AppStrings.Settings.optionalSync.swiftUIKey) {
            Toggle(AppStrings.Common.history.swiftUIKey, isOn: $history)
            Toggle(AppStrings.Navigation.metrics.swiftUIKey, isOn: $metrics)
            Toggle(AppStrings.Navigation.settings.swiftUIKey, isOn: $settings)
        }
        .disabled(!enabled)
    }
}
