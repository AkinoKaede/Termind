import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation
import UniformTypeIdentifiers

struct MobileSkillSettings: View {
    let skills: SkillLibraryModel
    @State private var editing: AgentSkill?
    @State private var deleting: AgentSkill?
    @State private var importing = false
    @State private var reset = false
    @State private var warnings: [String] = []
    @State private var error: String?
    private let markdown = UTType(filenameExtension: "md") ?? .plainText

    var body: some View {
        List {
            Section {
                if !skills.conflictingSkillIDs.isEmpty {
                    Text("Some skills have duplicate names and are paused. Rename them to resolve the conflict.")
                        .foregroundStyle(.orange)
                }
                ForEach(skills.skills) { skill in
                    Button {
                        editing = skill
                    } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.displayTitle)
                                Text(skill.effectiveName).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(skill.summary.isEmpty ? String(localized: "No description") : skill.summary)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !skill.isComplete {
                                    Text("Draft").font(.caption)
                                } else if !skill.isEnabled {
                                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = skill }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = skill }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = skill }
                    }
                }
            } footer: {
                Text(
                    "A skill is a procedure the assistant loads when a task matches its description, and then follows. It never approves an action: commands, writes and transfers still ask exactly as they would otherwise."
                )
            }
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if let error = error ?? skills.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Skill", systemImage: "plus") { editing = AgentSkill(name: "") }
                    .labelStyle(.iconOnly)
                Menu {
                    Button("Import Skill", systemImage: "square.and.arrow.down") { importing = true }
                    Divider()
                    Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) { reset = true }
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
        }
        .sheet(item: $editing) { MobileSkillEditor(library: skills, skill: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [markdown, .plainText, .folder]) { result in
            do {
                error = nil
                warnings = []
                let outcome = try SkillImporter.read(result.get())
                let installed = skills.install(outcome.document, importedFrom: outcome.origin)
                if let error = skills.storageError { throw MobileEditorError.message(error) }
                warnings = outcome.document.warnings + outcome.warnings
                editing = installed
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog(
            "Delete Skill",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Skill", role: .destructive) {
                if let deleting { skills.delete(id: deleting.id) }
                deleting = nil
            }
        }
        .confirmationDialog(
            "Replace every skill with the ones Termind ships with?", isPresented: $reset, titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { skills.resetToBuiltInSkills() }
        } message: {
            Text(
                "Skills you wrote, imported or edited are deleted. This cannot be undone — export anything you want to keep first."
            )
        }
    }
}

struct MobileSkillEditor: View {
    let library: SkillLibraryModel
    @State private var model: MobileSkillEditorModel
    @State private var exporting = false
    @State private var deleting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(library: SkillLibraryModel, skill: AgentSkill) {
        self.library = library
        _model = State(initialValue: MobileSkillEditorModel(library: library, skill: skill))
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Skill"), isDirty: model.isDirty, canSave: model.canSave,
            actions: toolbarActions,
            save: { try model.save() },
            content: {
                Section("Skill") {
                    LabeledContent("Title") {
                        TextField("Title", text: $model.draft.title.singleLineText, axis: .horizontal).singleLinePaste()
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Name") {
                        Text(
                            model.draft.effectiveName.isEmpty
                                ? String(localized: "Derived from the title") : model.draft.effectiveName
                        )
                        .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { model.draft.isEnabled && model.draft.isComplete },
                            set: { model.draft.isEnabled = $0 }
                        )
                    ).disabled(!model.draft.isComplete)
                    if let problem = AgentSkillNaming.problem(with: model.draft.effectiveName),
                        !model.draft.title.isEmpty
                    {
                        Text(problem.message).font(.caption).foregroundStyle(.orange)
                    } else if library.hasNameConflict(model.draft.effectiveName, excluding: model.draft.id) {
                        Text("Another skill already uses this name.").foregroundStyle(.orange)
                    }
                    if !model.draft.importedFrom.isEmpty {
                        LabeledContent("Imported From", value: model.draft.importedFrom)
                    }
                }
                Section("Description") {
                    TextEditor(text: $model.draft.summary).frame(minHeight: 90)
                    Text(
                        "What this does and when to use it. This is the only part the assistant sees until it loads the skill, so it decides whether the skill is used at all."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\(model.draft.summary.count)/\(AgentSkill.maximumSummaryCharacters)").font(.caption)
                }
                Section("Instructions") {
                    TextEditor(text: $model.draft.body).font(.body.monospaced()).frame(minHeight: 240)
                    Text("Markdown. Returned whole when the assistant loads this skill.").font(.caption)
                        .foregroundStyle(.secondary)
                    if model.draft.body.utf8.count > AgentSkill.maximumBodyBytes {
                        Text("Longer than \(DataSizeFormat.bytes(AgentSkill.maximumBodyBytes)).")
                            .foregroundStyle(.orange)
                    }
                }
                SkillPackageEditor(package: $model.draft.package, readResource: SkillImporter.readResource)
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        )
        .fileExporter(
            isPresented: $exporting, document: try? SkillPackageDocument(skill: model.draft),
            contentType: .folder, defaultFilename: model.draft.effectiveName
        ) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .confirmationDialog("Delete Skill?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(id: model.original.id)
                if let error = library.storageError { self.error = error } else { dismiss() }
            }
        }
    }

    private var toolbarActions: [MobileEditorToolbarAction] {
        var actions = [
            MobileEditorToolbarAction(
                id: "export", title: "Export", systemImage: "square.and.arrow.up",
                perform: { exporting = true })
        ]
        if library.skill(model.original.id) != nil {
            actions.append(
                MobileEditorToolbarAction(
                    id: "delete", title: "Delete", systemImage: "trash", role: .destructive,
                    startsGroup: true, perform: { deleting = true }))
        }
        return actions
    }
}
