// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindPresentation

struct OnboardingCoachMark: View {
    let presentation: OnboardingPresentation
    let dismiss: () -> Void
    let performAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(alignment: .top, spacing: Metrics.Space.l) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text(AppStrings.Onboarding.dismiss))
                .accessibilityLabel(Text(AppStrings.Onboarding.dismissOnboardingTip))
            }

            HStack {
                if presentation.mode == .preview {
                    Text(AppStrings.Onboarding.developerPreview)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(actionTitle, action: performAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(Metrics.Space.l)
        .frame(width: 360)
        .termindGlassSurface(cornerRadius: Metrics.Radius.large, isInteractive: true)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: TermindColor.shadow.opacity(0.22), radius: 18, y: 8)
        .transition(
            reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Onboarding.onboarding(title)))
    }

    private var title: String {
        switch presentation.step {
        case .quickOpen: String(localized: AppStrings.Onboarding.quicklyOpenAnything)
        case .statusBarPath: String(localized: AppStrings.Onboarding.yourCurrentPathIsAnAction)
        case .commandGenerator: String(localized: AppStrings.Onboarding.generateACommandWithAi)
        }
    }

    private var detail: String {
        switch presentation.step {
        case .quickOpen:
            String(localized: AppStrings.Onboarding.pressPToSearchPagesWorkspacesHostsAndCommands)
        case .statusBarPath:
            switch presentation.pathDirection {
            case .sshToSFTP:
                String(
                    localized:
                        AppStrings.SFTP.sftpPathExplanation
                )
            case .sftpToSSH:
                String(
                    localized:
                        AppStrings.Onboarding.sshPathExplanation
                )
            case nil:
                String(
                    localized:
                        AppStrings.Onboarding.pathNavigationExplanation)
            }
        case .commandGenerator:
            String(
                localized:
                    AppStrings.Onboarding.commandGeneratorExplanation
            )
        }
    }

    private var actionTitle: String {
        switch presentation.step {
        case .quickOpen: String(localized: AppStrings.Onboarding.tryIt)
        case .statusBarPath: String(localized: AppStrings.Onboarding.openIt)
        case .commandGenerator: String(localized: AppStrings.Onboarding.gotIt)
        }
    }

    private var symbol: String {
        switch presentation.step {
        case .quickOpen: "command.square"
        case .statusBarPath: "folder.badge.gearshape"
        case .commandGenerator: "sparkles"
        }
    }
}
