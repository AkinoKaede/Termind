import SwiftUI

struct DeveloperSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var isResettingTrialStorage = false
    @State private var resetResult: ResetResult?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                Text(verbatim: "Developer")
                    .font(.title2.weight(.semibold))
                Text(verbatim: "Debug-only entitlement simulation and trial maintenance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: Metrics.SettingsPage.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.Space.xxl)
            .padding(.vertical, Metrics.Space.xl)
            .termindGlassBar()

            Divider()

            Form {
                Section {
                    Picker(selection: developmentPreset) {
                        ForEach(DebugProAccessPreset.allCases) { preset in
                            Text(verbatim: preset.title).tag(preset)
                        }
                    } label: {
                        Text(verbatim: "Entitlement State")
                    }

                    LabeledContent {
                        Text(verbatim: app.proAccess.hasProAccess ? "Unlocked" : "Locked")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "Pro Access")
                    }

                    if case .trialActive(let expiresAt) = app.proAccess.status {
                        LabeledContent {
                            Text(expiresAt, format: .dateTime.year().month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(verbatim: "Trial Ends")
                        }
                    }

                    Text(verbatim: "The selected state lasts for this run only. Every Debug launch starts with Developer Pro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(verbatim: "Pro Entitlement")
                }

                Section {
                    Button(role: .destructive) {
                        resetTrialStorage()
                    } label: {
                        if isResettingTrialStorage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(verbatim: "Reset Trial Storage")
                        }
                    }
                    .disabled(isResettingTrialStorage)

                    if let resetResult {
                        Text(verbatim: resetResult.message)
                            .font(.caption)
                            .foregroundStyle(resetResult.isError ? .orange : .secondary)
                    }

                    Text(verbatim: "Removes the local trial proof, Keychain items, and the Development CloudKit trial record.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(verbatim: "Trial Maintenance")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: Metrics.SettingsPage.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var developmentPreset: Binding<DebugProAccessPreset> {
        Binding(
            get: { app.proAccess.developmentPreset },
            set: {
                resetResult = nil
                app.proAccess.selectDevelopmentPreset($0)
            }
        )
    }

    private func resetTrialStorage() {
        isResettingTrialStorage = true
        resetResult = nil
        Task {
            do {
                try await app.proAccess.resetTrialStorageForDevelopment()
                resetResult = ResetResult(
                    message: "Trial storage was reset. The simulated state is now Free / Trial Available.",
                    isError: false
                )
            } catch {
                resetResult = ResetResult(message: error.localizedDescription, isError: true)
            }
            isResettingTrialStorage = false
        }
    }
}

private struct ResetResult {
    let message: String
    let isError: Bool
}
