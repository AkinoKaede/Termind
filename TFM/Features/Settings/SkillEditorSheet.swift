import AgentKit
import SwiftUI
import TermindInfrastructure
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
/// strand `skill_read_file` calls that are still in a transcript.
struct SkillEditorPage: View {
    let skillID: AgentSkill.ID
    let deleted: () -> Void
    @State private var replacementName = ""

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
                    SkillPackageEditor(package: binding(\.package), readResource: SkillImporter.readResource)
                    Section {
                        // One row, with the destructive action at the far
                        // trailing edge. Stacked, the two read as a list of
                        // equals and Delete sits directly under the pointer
                        // after an Export.
                        HStack {
                            Button(AppStrings.Common.export.swiftUIKey) { export(skill) }
                            Spacer(minLength: Metrics.Space.m)
                            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                                app.skills.delete(id: skillID)
                                deleted()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(AppStrings.Settings.skillDeleted.swiftUIKey, systemImage: "trash")
            }
        }
        .onDisappear { app.skills.lockName(for: skillID) }
    }

    // MARK: - Sections

    @ViewBuilder
    private func identitySection(_ skill: AgentSkill) -> some View {
        Section {
            TextField(AppStrings.Common.title.swiftUIKey, text: binding(\.title).singleLineText, axis: .horizontal)
                .singleLinePaste().lineLimit(1)

            if isNameLocked {
                LabeledContent(AppStrings.Common.name.swiftUIKey) {
                    Text(skill.name)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                LabeledContent(AppStrings.Common.name.swiftUIKey) {
                    Text(
                        derivedName.isEmpty ? String(localized: AppStrings.Settings.derivedFromTheTitle) : derivedName
                    )
                    .font(.callout.monospaced())
                    .foregroundStyle(derivedName.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                }
            }

            Toggle(
                AppStrings.Common.enabled.swiftUIKey,
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
                TextField(AppStrings.Common.name.swiftUIKey, text: $replacementName.singleLineText).singleLinePaste()
                Button(AppStrings.Common.rename.swiftUIKey) {
                    app.skills.renameConflictingSkill(skillID, to: replacementName)
                }
                .disabled(
                    !AgentSkillNaming.isValid(replacementName)
                        || app.skills.hasNameConflict(replacementName, excluding: skillID))
                Label(
                    AppStrings.Settings.anotherSkillAlreadyUsesThisName.swiftUIKey,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !skill.importedFrom.isEmpty {
                LabeledContent(AppStrings.Settings.importedFrom.swiftUIKey) {
                    Text(skill.importedFrom)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(AppStrings.Settings.skill)
        }
    }

    @ViewBuilder
    private func descriptionSection(_ skill: AgentSkill) -> some View {
        Section {
            TextEditor(text: binding(\.summary))
                .autohidingScrollers()
                .font(.callout)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)

            HStack {
                Text(
                    AppStrings.Settings.skillDescriptionExplanation
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
            Text(AppStrings.Settings.description)
        }
    }

    @ViewBuilder
    private func bodySection(_ skill: AgentSkill) -> some View {
        Section {
            TextEditor(text: binding(\.body))
                .autohidingScrollers()
                .font(.callout.monospaced())
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)

            HStack {
                Text(AppStrings.Settings.skillBodyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: Metrics.Space.m)

                if skill.body.utf8.count > AgentSkill.maximumBodyBytes {
                    Label(
                        AppStrings.Settings.longerThan(DataSizeFormat.bytes(AgentSkill.maximumBodyBytes)).swiftUIKey,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(AppStrings.Settings.instructions)
        }
    }

    // MARK: - Actions

    /// Writes the skill back out in the portable format, so one written here can
    /// be dropped into a pi or Claude Code skills directory.
    private func export(_ skill: AgentSkill) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let accessed = parent.startAccessingSecurityScopedResource()
        defer { if accessed { parent.stopAccessingSecurityScopedResource() } }
        do {
            let destination = parent.appending(path: skill.effectiveName, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try SkillPackageDocument(skill: skill).write(to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
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
