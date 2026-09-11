import SwiftUI

struct DeveloperSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                ForEach(OnboardingStep.allCases) { step in
                    onboardingRow(step)
                }

                if app.onboarding.previewRequest != nil
                    || app.onboarding.presentation?.mode == .preview
                {
                    Button {
                        app.onboarding.cancelPreview()
                    } label: {
                        Text(verbatim: "Cancel Preview")
                    }
                }

                Button(role: .destructive) {
                    app.onboarding.resetAll()
                } label: {
                    Text(verbatim: "Reset All Onboarding")
                }

                Text(
                    verbatim: "Preview bypasses completion and ordering but waits for a real "
                        + "eligible context. Preview actions never change completion state."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(verbatim: "Onboarding")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func onboardingRow(_ step: OnboardingStep) -> some View {
        let status = app.onboarding.developerStatus(for: step)
        return VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text(verbatim: step.title)
                    Text(verbatim: status.label)
                        .font(.caption)
                        .foregroundStyle(onboardingStatusColor(status))
                }
                Spacer()
                Button {
                    app.onboarding.preview(step)
                } label: {
                    Text(verbatim: "Preview")
                }
                Button {
                    app.onboarding.reset(step)
                } label: {
                    Text(verbatim: "Reset")
                }
            }

            if case .waitingForContext(let reason) = status {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func onboardingStatusColor(_ status: OnboardingDeveloperStatus) -> Color {
        switch status {
        case .completed: .green
        case .pending: .secondary
        case .previewing: .orange
        case .waitingForContext: .orange
        }
    }
}
