import AgentKit
import SwiftUI
import TermindPresentation
import UniformTypeIdentifiers

/// One skill: what it is called, when the assistant should reach for it, and
/// what it says.
///
/// The description field is the one that decides whether a skill is ever used.
/// It is all the model has until it loads the body, so the caption under it says
/// exactly that rather than leaving it to be discovered by a skill that quietly
/// never fires.
///
/// The name locks on first save, like `MCPServer.namespaceID`: it is how a
/// conversation already in progress refers to this skill, and moving it would
/// strand `load_skill` calls that are still in a transcript.
struct SkillEditorPage: View {
    let skillID: AgentSkill.ID
    let deleted: () -> Void

    @Environment(AppModel.self) private var app

    private var skill: AgentSkill? { app.skills.skill(skillID) }

    private var derivedName: String { skill?.effectiveName ?? "" }

    private var isNameLocked: Bool { !(skill?.name.isEmpty ?? true) }

    private var nameProblem: AgentSkillNaming.Problem? {
        AgentSkillNaming.problem(with: derivedName)
    }

    private var hasNameConflict: Bool {
        app.skills.hasNameConflict(derivedName, excluding: skillID)
    }

    var body: some View {
        Group {
            if let skill {
                Form {
                    identitySection(skill)
                    descriptionSection(skill)
                    bodySection(skill)
                    Section {
                        // One row, with the destructive action at the far
                        // trailing edge. Stacked, the two read as a list of
                        // equals and Delete sits directly under the pointer
                        // after an Export.
                        HStack {
                            Button("Export as SKILL.md") { export(skill) }
                            Spacer(minLength: Metrics.Space.m)
                            Button("Delete Skill", role: .destructive) {
                                app.skills.delete(id: skillID)
                                deleted()
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("Skill Deleted", systemImage: "trash")
            }
        }
        .onDisappear { app.skills.lockName(for: skillID) }
    }

    // MARK: - Sections

    @ViewBuilder
    private func identitySection(_ skill: AgentSkill) -> some View {
        Section {
            TextField("Title", text: binding(\.title).singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)

            if isNameLocked {
                LabeledContent("Name") {
                    Text(skill.name)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                LabeledContent("Name") {
                    Text(derivedName.isEmpty ? String(localized: "Derived from the title") : derivedName)
                        .font(.callout.monospaced())
                        .foregroundStyle(derivedName.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { skill.isEnabled && skill.isComplete },
                    set: { app.skills.setEnabled($0, for: skillID) }
                )
            ).disabled(!skill.isComplete)

            if let nameProblem, !derivedName.isEmpty || !skill.title.isEmpty {
                Label(nameProblem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasNameConflict {
                Label("Another skill already uses this name.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !skill.importedFrom.isEmpty {
                LabeledContent("Imported From") {
                    Text(skill.importedFrom)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Skill")
        }
    }

    @ViewBuilder
    private func descriptionSection(_ skill: AgentSkill) -> some View {
        Section {
            TextEditor(text: binding(\.summary))
                .font(.callout)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)

            HStack {
                Text(
                    "What this does and when to use it. This is the only part the assistant sees until it loads the skill, so it decides whether the skill is used at all."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Metrics.Space.m)

                Text("\(skill.summary.count)/\(AgentSkill.maximumSummaryCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        skill.summary.count > AgentSkill.maximumSummaryCharacters
                            ? .orange : .secondary
                    )
            }
        } header: {
            Text("Description")
        }
    }

    @ViewBuilder
    private func bodySection(_ skill: AgentSkill) -> some View {
        Section {
            TextEditor(text: binding(\.body))
                .font(.callout.monospaced())
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)

            HStack {
                Text("Markdown. Returned whole when the assistant loads this skill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: Metrics.Space.m)

                if skill.body.utf8.count > AgentSkill.maximumBodyBytes {
                    Label(
                        "Longer than \(DataSizeFormat.bytes(AgentSkill.maximumBodyBytes)).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Instructions")
        }
    }

    // MARK: - Actions

    /// Writes the skill back out in the portable format, so one written here can
    /// be dropped into a pi or Claude Code skills directory.
    private func export(_ skill: AgentSkill) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SKILL.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try? Data(AgentSkillDocument.render(skill).utf8).write(to: url)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentSkill, Value>) -> Binding<Value> {
        Binding(
            get: {
                app.skills.skill(skillID)?[keyPath: keyPath]
                    ?? AgentSkill(name: "")[keyPath: keyPath]
            },
            set: { newValue in
                guard var skill = app.skills.skill(skillID) else { return }
                skill[keyPath: keyPath] = newValue
                app.skills.upsert(skill)
            }
        )
    }
}
