import SwiftUI

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
                .help(Text("Dismiss"))
                .accessibilityLabel(Text("Dismiss onboarding tip"))
            }

            HStack {
                if presentation.mode == .preview {
                    Text(verbatim: "Developer Preview")
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
        .accessibilityLabel(Text("Onboarding: \(title)"))
    }

    private var title: String {
        switch presentation.step {
        case .quickOpen: String(localized: "Quickly open anything")
        case .statusBarPath: String(localized: "Your current path is an action")
        case .commandGenerator: String(localized: "Generate a command with AI")
        }
    }

    private var detail: String {
        switch presentation.step {
        case .quickOpen:
            String(localized: "Press ⌘P to search pages, workspaces, hosts, and commands.")
        case .statusBarPath:
            switch presentation.pathDirection {
            case .sshToSFTP:
                String(
                    localized:
                        "Click the path to open this directory with SFTP. Right-click to copy it or open it in a new workspace."
                )
            case .sftpToSSH:
                String(
                    localized:
                        "Click the path to open this directory with SSH. Right-click to copy it or open it in a new workspace."
                )
            case nil:
                String(
                    localized:
                        "Click the path to open the same directory in another session. Right-click for more options.")
            }
        case .commandGenerator:
            String(
                localized:
                    "Type what you want to do at the shell prompt, then press ⌘I. The generated command is inserted but never run automatically."
            )
        }
    }

    private var actionTitle: String {
        switch presentation.step {
        case .quickOpen: String(localized: "Try It")
        case .statusBarPath: String(localized: "Open It")
        case .commandGenerator: String(localized: "Got It")
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
