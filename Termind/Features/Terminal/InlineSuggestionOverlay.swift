import SwiftUI

/// The single-line suggestion that floats above the prompt.
///
/// It only appears when the remote shell reported OSC 133 markers — without them
/// there is no way to know where the prompt is, and a floating box in the middle
/// of `top` output would be worse than nothing. `canShowInlineSuggestions` gates
/// this, and the degraded path (Context Panel only) is the default, not the fallback.
struct InlineSuggestionOverlay: View {
    let suggestion: SuggestedCommand
    let sshSession: SSHSessionModel
    /// Insert goes through the Workspace rather than straight at the sshSession:
    /// with broadcast on, a suggestion accepted in one pane is meant for every
    /// shell in the group. See `Workspace.deliver`.
    let workspace: Workspace

    @AppStorage(SettingsKey.allowOneClickSafeCommands) private var allowOneClickSafe = false

    private var assessment: RiskAssessment { suggestion.risk }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text(suggestion.command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Metrics.Space.m)
                RiskBadge(assessment: assessment)
            }

            if !suggestion.explanation.isEmpty {
                Text(suggestion.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: Metrics.Space.l) {
                KeyHint(key: "⏎", action: primaryActionLabel)
                KeyHint(key: "⇥", action: "Complete")
                KeyHint(key: "⎋", action: "Dismiss")
            }
        }
        .padding(Metrics.Space.l)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: Metrics.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(assessment.risk.tint.opacity(0.35))
        }
        .shadow(radius: 12, y: 4)
        .overlay { shortcuts }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Suggested command: \(suggestion.command)"))
    }

    /// Zero-size buttons purely to register key equivalents while the overlay is
    /// on screen.
    private var shortcuts: some View {
        ZStack {
            Button("", action: primary).keyboardShortcut(.return, modifiers: [])
            Button("", action: complete).keyboardShortcut(.tab, modifiers: [])
            Button("", action: sshSession.dismissSuggestion).keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Return only *runs* a read-only command, and only if the user turned that
    /// on. Everything else it merely types onto the prompt, leaving the actual
    /// Return keystroke to the user.
    private var runsOnReturn: Bool {
        assessment.risk == .safe && allowOneClickSafe
    }

    private var primaryActionLabel: LocalizedStringKey {
        runsOnReturn ? "Run" : "Insert"
    }

    private func primary() {
        workspace.deliver(suggestion.command, from: sshSession, submit: runsOnReturn)
        sshSession.dismissSuggestion()
    }

    private func complete() {
        workspace.deliver(suggestion.command, from: sshSession)
        sshSession.dismissSuggestion()
    }
}

private struct KeyHint: View {
    let key: String
    let action: LocalizedStringKey

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Text(key)
                .font(.caption2.monospaced())
                .padding(.horizontal, Metrics.Space.xs)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 3))
            Text(action)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
