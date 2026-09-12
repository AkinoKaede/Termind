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
                Label("Up to date · \(formatted)", systemImage: "checkmark.icloud")
            } else {
                Label("Up to date", systemImage: "checkmark.icloud")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }
}
