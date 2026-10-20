// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

public struct VaultSyncStatusLabel: View {
    public let status: VaultSyncStatus
    @Environment(\.locale) private var locale

    public init(status: VaultSyncStatus) { self.status = status }

    @ViewBuilder
    public var body: some View {
        switch status {
        case .checkingAccount:
            Label("Checking iCloud…", systemImage: "icloud")
        case .paused:
            Label("Paused", systemImage: "pause.circle")
        case .signInRequired:
            Label(AppStrings.Settings.signInToSync, systemImage: "icloud.slash").foregroundStyle(.secondary)
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
        case .partiallyBlocked(let pendingCount, let blockedCount, let requiresUpdate):
            VStack(alignment: .leading, spacing: 4) {
                Label("Paused uploads: \(blockedCount)", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text(
                    "This version cannot safely process some iCloud records. Their local changes are kept on this device."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if requiresUpdate {
                    Text("A newer version of Termind is required to edit some of these records.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pendingCount > 0 {
                    Text("Pending uploads: \(pendingCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .upToDate(let lastSync):
            if let lastSync {
                let formatted = lastSync.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
                )
                Label("Up to date · \(formatted)", systemImage: "checkmark.icloud")
            } else {
                Label("Up to date", systemImage: "checkmark.icloud")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }
}
