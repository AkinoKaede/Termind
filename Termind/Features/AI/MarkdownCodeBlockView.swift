import SwiftUI

/// A fenced code block inside a message.
///
/// A shell fence in assistant output is the one thing this app's transcript can
/// do that a general Markdown renderer cannot: classify it locally and offer to
/// put it at a prompt. Every other language is just code, and gets a copy
/// button.
struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    /// Only assistant output offers to run the shell it wrote. A fence the user
    /// pasted is their own text; "suggested command" is not what it means.
    var isActionable = false

    private static let shellLanguages: Set<String> = [
        "bash", "sh", "zsh", "shell", "console", "terminal",
    ]

    private var isShell: Bool {
        guard let language else { return false }
        return Self.shellLanguages.contains(language.lowercased())
    }

    private var isEmpty: Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Environment(\.markdownFillsWidth) private var fillsWidth

    var body: some View {
        if isActionable, isShell, !isEmpty {
            ShellCodeBlockView(language: language ?? "", command: code)
        } else {
            plain
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            HStack(spacing: Metrics.Space.xs) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                CopyButton(text: code)
            }
            Text(code)
                .font(MarkdownTypography.monospaced)
                .textSelection(.enabled)
                .markdownWidth(fills: fillsWidth)
        }
        .padding(Metrics.Chat.codeInset)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Metrics.Radius.small))
    }
}

// MARK: - Shell

private struct ShellCodeBlockView: View {
    let language: String
    let command: String

    @Environment(WindowModel.self) private var window
    @State private var isConfirming = false

    private var assessment: RiskAssessment { CommandRiskClassifier.assess(command) }

    /// Whether this fence may be delivered to a prompt at all.
    ///
    /// `SSHSessionModel.insert` writes raw bytes with no bracketed-paste
    /// wrapper, so an embedded newline reaches the PTY as Return. "Insert" on a
    /// three-line script would execute the first two lines while presenting
    /// itself as a preview — so multi-line fences get the badge and a copy
    /// button and nothing that touches the session.
    private var isSingleLine: Bool { !command.contains("\n") }

    /// The shell this card would reach.
    ///
    /// `selectedTab` is `nil` whenever the pinned Assistant tab is showing, and
    /// that is exactly where the full-width transcript lives — so the buttons
    /// disable there instead of looking live and doing nothing.
    private var target: SSHSessionModel? {
        guard let tab = window.selectedTab else { return nil }
        return tab.focusedPane.sshSession ?? tab.broadcastTargets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.xs) {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Metrics.Space.s)
                RiskBadge(assessment: assessment)
            }

            Text(command)
                .font(MarkdownTypography.monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(Metrics.Chat.codeInset)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: Metrics.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                .strokeBorder(assessment.risk == .destructive ? Color.red.opacity(0.4) : .clear)
        }
        .confirmationDialog(
            Text("Run a destructive command?"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Run \(command)", role: .destructive) { deliver(submit: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(assessment.reasons.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Metrics.Space.s) {
            if isSingleLine {
                Button("Insert") { deliver(submit: false) }
                    .disabled(target == nil)
                Button("Run") { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(assessment.risk == .destructive ? .red : .accentColor)
                    .disabled(target == nil)
            } else {
                Text("Several commands — copy and review before running.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Metrics.Space.s)
            CopyButton(text: command)
        }
        .controlSize(.small)
        .help(Text(target == nil ? "No shell in the foreground" : ""))
    }

    private func run() {
        if assessment.requiresSecondConfirmation {
            isConfirming = true
        } else {
            deliver(submit: true)
        }
    }

    /// Through `Workspace.deliver`, so a card obeys the same broadcast rule as
    /// every other programmatic route to a prompt. `submit: false` writes
    /// without the newline; the user's own Return is what runs it.
    private func deliver(submit: Bool) {
        guard let tab = window.selectedTab, let origin = target else { return }
        tab.deliver(command, from: origin, submit: submit)
    }
}

// MARK: - Copy

/// A copy button that confirms itself for a moment, so a click on a glyph that
/// produces no visible change still reads as having worked.
struct CopyButton: View {
    let text: String

    @State private var hasCopied = false

    var body: some View {
        Button {
            copyToPasteboard(text)
            hasCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                hasCopied = false
            }
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(Text("Copy"))
        .accessibilityLabel(Text("Copy"))
    }
}
