import SwiftUI

extension CommandRisk {
    var tint: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .destructive: .red
        }
    }
}

/// The risk label shown on every proposed command.
///
/// The rating comes from `CommandRiskClassifier` running locally, never from the
/// model's own description of what it suggested.
struct RiskBadge: View {
    let assessment: RiskAssessment
    var compact = false

    var body: some View {
        Label {
            if !compact { Text(assessment.risk.label) }
        } icon: {
            Image(systemName: assessment.risk.symbol)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(assessment.risk.tint)
        .padding(.horizontal, compact ? 0 : Metrics.Space.s)
        .padding(.vertical, 2)
        .background {
            if !compact {
                Capsule().fill(assessment.risk.tint.opacity(0.12))
            }
        }
        .help(Text(assessment.reasons.first ?? assessment.risk.label))
    }
}

/// A command the assistant proposed, with the actions the user can take on it.
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ ✦ Suggested command      ⚠ Destructive│
/// │ rm -rf /var/log/nginx/*.gz           │
/// │ Deletes rotated nginx logs — 2.1 GB. │
/// │ [ Insert ]  [ Run ]  [ Explain ]     │
/// └──────────────────────────────────────┘
/// ```
struct CommandCardView: View {
    let command: SuggestedCommand

    @Environment(WindowModel.self) private var window
    @State private var isConfirming = false

    private var assessment: RiskAssessment { command.risk }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack {
                Label("Suggested Command", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                RiskBadge(assessment: assessment)
            }

            Text(command.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.Space.m)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Metrics.Radius.small))

            if !command.explanation.isEmpty {
                Text(command.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Showing *why* something was flagged is what makes the badge worth
            // trusting; an unexplained warning trains people to click through.
            if !assessment.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(assessment.reasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.caption2)
                            .foregroundStyle(assessment.risk.tint)
                    }
                }
            }

            HStack(spacing: Metrics.Space.s) {
                Button("Insert") { insert(run: false) }
                Button(runTitle) { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(assessment.risk == .destructive ? .red : .accentColor)
                Spacer()
                Button {
                    copyToPasteboard(command.command)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(Text("Copy"))
            }
            .controlSize(.small)
        }
        .padding(Metrics.Space.l)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: Metrics.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                .strokeBorder(assessment.risk == .destructive ? Color.red.opacity(0.4) : .clear)
        }
        .confirmationDialog(
            Text("Run a destructive command?"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Run \(command.command)", role: .destructive) { insert(run: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(assessment.reasons.joined(separator: "\n"))
        }
    }

    private var runTitle: LocalizedStringKey {
        "Run"
    }

    private func run() {
        if assessment.requiresSecondConfirmation {
            isConfirming = true
        } else {
            insert(run: true)
        }
    }

    /// Through `Workspace.deliver`, which decides how far the command travels:
    /// the one pane, or every shell in the Workspace when broadcast is on.
    ///
    /// The focused pane first, falling back to the Workspace's first shell for a
    /// card clicked while a file browser has focus. The Context Panel's context
    /// chips already describe the focused pane, so the command it suggested
    /// should land in the shell it was talking about.
    ///
    /// `run: false` writes to SSH stdin without a newline and `run: true`
    /// appends one — the user's
    /// Return key is the only thing that ever submits a command they did not
    /// explicitly choose to run.
    private func insert(run: Bool) {
        guard let tab = window.selectedTab,
            let sshSession = tab.focusedPane.sshSession ?? tab.broadcastTargets.first
        else { return }
        tab.deliver(command.command, from: sshSession, submit: run)
    }
}
