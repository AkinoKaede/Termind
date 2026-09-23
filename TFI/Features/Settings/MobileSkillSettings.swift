import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation
import UniformTypeIdentifiers

struct MobileSkillSettings: View {
    let skills: SkillLibraryModel
    @State private var editing: AgentSkill?
    @State private var importing = false
    @State private var warnings: [String] = []
    @State private var error: String?
    private let markdown = UTType(filenameExtension: "md") ?? .plainText

    var body: some View {
        List {
            Section {
                if !skills.conflictingSkillIDs.isEmpty {
                    Text(TermindCopy.Settings.duplicateSkillNames)
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
                                Text(
                                    skill.summary.isEmpty
                                        ? String(localized: TermindCopy.Settings.noDescription) : skill.summary
                                )
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !skill.isComplete {
                                    Text(TermindCopy.Settings.draft).font(.caption)
                                } else if !skill.isEnabled {
                                    Text(TermindCopy.Settings.disabled).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(TermindCopy.Common.edit.swiftUIKey, systemImage: "pencil") { editing = skill }
                        Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            skills.delete(id: skill.id)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            skills.delete(id: skill.id)
                        }
                    }
                }
            } footer: {
                Text(
                    TermindCopy.Settings.skillExplanation
                )
            }
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if let error = error ?? skills.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(TermindCopy.Settings.skills.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(TermindCopy.Settings.addSkill.swiftUIKey, systemImage: "plus") { editing = AgentSkill(name: "") }
                    .labelStyle(.iconOnly)
            }
            .mobileProminentAction()
            MobileToolbarOverflow {
                Button(TermindCopy.Settings.importSkill.swiftUIKey, systemImage: "square.and.arrow.down") {
                    importing = true
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
    }
}

struct MobileSkillEditor: View {
    let library: SkillLibraryModel
    @State private var model: MobileSkillEditorModel
    @State private var exporting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(library: SkillLibraryModel, skill: AgentSkill) {
        self.library = library
        _model = State(initialValue: MobileSkillEditorModel(library: library, skill: skill))
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: TermindCopy.Settings.skill), isDirty: model.isDirty, canSave: model.canSave,
            actions: toolbarActions,
            save: { try model.save() },
            content: {
                Section(TermindCopy.Settings.skill.swiftUIKey) {
                    LabeledContent(TermindCopy.Common.title.swiftUIKey) {
                        TextField(
                            TermindCopy.Common.title.swiftUIKey, text: $model.draft.title.singleLineText,
                            axis: .horizontal
                        ).singleLinePaste()
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }
                    if library.conflictingSkillIDs.contains(model.original.id) {
                        TextField(TermindCopy.Common.name.swiftUIKey, text: $model.draft.name.singleLineText)
                            .singleLinePaste()
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent(TermindCopy.Common.name.swiftUIKey) {
                        Text(
                            model.draft.effectiveName.isEmpty
                                ? String(localized: TermindCopy.Settings.derivedFromTheTitle)
                                : model.draft.effectiveName
                        )
                        .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Toggle(
                        TermindCopy.Common.enabled.swiftUIKey,
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
                        Text(TermindCopy.Settings.anotherSkillAlreadyUsesThisName).foregroundStyle(.orange)
                    }
                    if !model.draft.importedFrom.isEmpty {
                        LabeledContent(TermindCopy.Settings.importedFrom.swiftUIKey, value: model.draft.importedFrom)
                    }
                }
                Section(TermindCopy.Settings.description.swiftUIKey) {
                    TextEditor(text: $model.draft.summary).frame(minHeight: 90)
                    Text(
                        TermindCopy.Settings.skillDescriptionExplanation
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\(model.draft.summary.count)/\(AgentSkill.maximumSummaryCharacters)").font(.caption)
                }
                Section(TermindCopy.Settings.instructions.swiftUIKey) {
                    TextEditor(text: $model.draft.body).font(.body.monospaced()).frame(minHeight: 240)
                    Text(TermindCopy.Settings.skillBodyExplanation).font(.caption)
                        .foregroundStyle(.secondary)
                    if model.draft.body.utf8.count > AgentSkill.maximumBodyBytes {
                        Text(TermindCopy.Settings.longerThan(DataSizeFormat.bytes(AgentSkill.maximumBodyBytes)))
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
    }

    private var toolbarActions: [MobileEditorToolbarAction] {
        var actions = [
            MobileEditorToolbarAction(
                id: "export", title: TermindCopy.Common.export, systemImage: "square.and.arrow.up",
                perform: { exporting = true })
        ]
        if library.skill(model.original.id) != nil {
            actions.append(
                MobileEditorToolbarAction(
                    id: "delete", title: TermindCopy.Common.delete, systemImage: "trash", role: .destructive,
                    startsGroup: true, perform: delete))
        }
        return actions
    }

    private func delete() {
        library.delete(id: model.original.id)
        if let error = library.storageError { self.error = error } else { dismiss() }
    }
}
