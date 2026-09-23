import SwiftUI
import TermindPresentation

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
                        Text(AppStrings.Onboarding.cancelPreview)
                    }
                }

                Button(role: .destructive) {
                    app.onboarding.resetAll()
                } label: {
                    Text(AppStrings.Onboarding.resetAll)
                }

                Text(AppStrings.Onboarding.previewExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(AppStrings.Onboarding.title)
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
                    Text(step.title)
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(onboardingStatusColor(status))
                }
                Spacer()
                Button {
                    app.onboarding.preview(step)
                } label: {
                    Text(AppStrings.Onboarding.preview)
                }
                Button {
                    app.onboarding.reset(step)
                } label: {
                    Text(AppStrings.Onboarding.reset)
                }
            }

            if case .waitingForContext(let reason) = status {
                Text(reason)
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
