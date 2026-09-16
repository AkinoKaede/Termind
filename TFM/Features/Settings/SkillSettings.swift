import AgentKit
import SwiftUI
import TermindInfrastructure
import UniformTypeIdentifiers

/// The "Skills" section: procedures the assistant may load and follow.
///
/// The footnote is doing real work. A skill is the one thing in Termind whose
/// text the model treats as instructions rather than data, so the page has to
/// say both halves of that: it is followed, and it still cannot approve
/// anything. Someone importing a file from the internet should read that before
/// they enable it, not after.
struct SkillSettings: View {
    @Environment(AppModel.self) private var app
    let edit: (AgentSkill.ID, Bool) -> Void

    @State private var importError: String?
    @State private var importWarnings: [String] = []
    @State private var isConfirmingReset = false

    var body: some View {
        Section {
            if !app.skills.conflictingSkillIDs.isEmpty {
                Label(
                    "Some skills have duplicate names and are paused. Rename them to resolve the conflict.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            ForEach(app.skills.skills) { skill in
                SkillRow(skill: skill) { edit(skill.id, false) }
            }

            FormNavigationAction(title: "Add Skill") {
                let skill = AgentSkill(name: "")
                app.skills.upsert(skill)
                edit(skill.id, true)
            }

            HStack {
                Button("Import Skill") { importSkill() }
                Spacer(minLength: Metrics.Space.m)
                Button("Reset") { isConfirmingReset = true }
            }
            .confirmationDialog(
                "Replace every skill with the ones Termind ships with?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    importError = nil
                    importWarnings = []
                    app.skills.resetToBuiltInSkills()
                }
                Button("Cancel", role: .cancel) { isConfirmingReset = false }
            } message: {
                Text(
                    "Skills you wrote, imported or edited are deleted. This cannot be undone — export anything you want to keep first."
                )
            }

            Text(
                "A skill is a procedure the assistant loads when a task matches its description, and then follows. It never approves an action: commands, writes and transfers still ask exactly as they would otherwise."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(importWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = app.skills.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Skills")
        }
    }

    /// Reads a `SKILL.md` — or a folder holding one — and copies it into the
    /// library.
    ///
    /// A copy rather than a link, and no bookmark is kept. Termind is sandboxed,
    /// so a live folder would mean holding a security-scoped bookmark and
    /// rescanning someone else's directory on every launch; taking the content
    /// once, here, is both smaller and easier to reason about — what the agent
    /// can read is what the user imported, not whatever that path holds today.
    private func importSkill() {
        importError = nil
        importWarnings = []
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = String(localized: "Choose a SKILL.md file, or a folder that contains one.")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let outcome = try SkillImporter.read(url)
            let skill = app.skills.install(outcome.document, importedFrom: outcome.origin)
            importWarnings = outcome.document.warnings + outcome.warnings
            edit(skill.id, false)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct SkillRow: View {
    let skill: AgentSkill
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.displayTitle)
                    .lineLimit(1)
                Text(skill.effectiveName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(
                    skill.summary.isEmpty
                        ? String(localized: "No description") : skill.summary
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: Metrics.Space.m)

            if !skill.isComplete {
                CardChip(text: String(localized: "Draft"), symbol: "pencil.line")
            }

            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!skill.isComplete)
                .accessibilityLabel(Text("Enable \(skill.displayTitle)"))

            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit \(skill.displayTitle)"))
        }
        .contentShape(.rect)
        .onTapGesture(perform: edit)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { skill.isEnabled && skill.isComplete },
            set: { app.skills.setEnabled($0, for: skill.id) }
        )
    }
}
