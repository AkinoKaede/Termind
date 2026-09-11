import SwiftUI
import TermindApplication
import TermindRemoteInfrastructure

nonisolated struct MobileSFTPTransferLimits: Equatable, Sendable {
    let global: Int
    let perHost: Int

    init(global: Int, perHost: Int) {
        self.global = min(
            max(global, SharedSettingsKey.sftpTransferLimitRange.lowerBound),
            SharedSettingsKey.sftpTransferLimitRange.upperBound
        )
        self.perHost = min(
            max(perHost, SharedSettingsKey.sftpTransferLimitRange.lowerBound), self.global)
    }
}

struct MobileSFTPSettingsView: View {
    let transfers: SFTPTransferCoordinator
    @AppStorage(SharedSettingsKey.sftpGlobalTransferLimit) private var globalLimit = SharedSettingsKey
        .defaultSFTPGlobalTransferLimit
    @AppStorage(SharedSettingsKey.sftpPerHostTransferLimit) private var perHostLimit = SharedSettingsKey
        .defaultSFTPPerHostTransferLimit

    var body: some View {
        Form {
            Section("SFTP") {
                Stepper(value: $globalLimit, in: SharedSettingsKey.sftpTransferLimitRange) {
                    LabeledContent("Concurrent Transfers") {
                        Text(globalLimit, format: .number).monospacedDigit()
                    }
                }
                Stepper(value: $perHostLimit, in: perHostRange) {
                    LabeledContent("Per-Host Transfers") {
                        Text(perHostLimit, format: .number).monospacedDigit()
                    }
                }
                Text(
                    "Changes apply to queued transfers. Active transfers continue unchanged. Unsaved credentials limit a session to one transfer at a time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SFTP")
        .onAppear { applyLimits() }
        .onChange(of: globalLimit) { applyLimits() }
        .onChange(of: perHostLimit) { applyLimits() }
    }

    private var perHostRange: ClosedRange<Int> {
        let minimum = SharedSettingsKey.sftpTransferLimitRange.lowerBound
        return minimum...max(globalLimit, minimum)
    }

    private func applyLimits() {
        let limits = MobileSFTPTransferLimits(global: globalLimit, perHost: perHostLimit)
        if globalLimit != limits.global {
            globalLimit = limits.global
            return
        }
        if perHostLimit != limits.perHost {
            perHostLimit = limits.perHost
            return
        }
        transfers.updateLimits(global: limits.global, perHost: limits.perHost)
    }
}
