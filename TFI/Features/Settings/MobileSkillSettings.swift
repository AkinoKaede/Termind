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
                    Text(AppStrings.Settings.duplicateSkillNames)
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
                                        ? String(localized: AppStrings.Settings.noDescription) : skill.summary
                                )
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !skill.isComplete {
                                    Text(AppStrings.Settings.draft).font(.caption)
                                } else if !skill.isEnabled {
                                    Text(AppStrings.Settings.disabled).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") { editing = skill }
                        Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            skills.delete(id: skill.id)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            skills.delete(id: skill.id)
                        }
                    }
                }
            }
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if let error = error ?? skills.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(AppStrings.Settings.skills.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(AppStrings.Settings.addSkill.swiftUIKey, systemImage: "plus") { editing = AgentSkill(name: "") }
                    .labelStyle(.iconOnly)
            }
            .mobileProminentAction()
            MobileToolbarOverflow {
                Button(AppStrings.Common.import.swiftUIKey, systemImage: "square.and.arrow.down") {
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
            title: String(localized: AppStrings.Settings.skill), isDirty: model.isDirty, canSave: model.canSave,
            actions: toolbarActions,
            discardQuestion: library.skill(model.original.id) == nil
                ? AppStrings.Common.discardNewSkillQuestion : AppStrings.Common.discardChangesQuestion,
            save: { try model.save() },
            content: {
                Section(AppStrings.Settings.skill.swiftUIKey) {
                    LabeledContent(AppStrings.Common.title.swiftUIKey) {
                        TextField(
                            AppStrings.Common.title.swiftUIKey, text: $model.draft.title.singleLineText,
                            axis: .horizontal
                        ).singleLinePaste()
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }
                    if library.conflictingSkillIDs.contains(model.original.id) {
                        TextField(AppStrings.Common.name.swiftUIKey, text: $model.draft.name.singleLineText)
                            .singleLinePaste()
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent(AppStrings.Common.name.swiftUIKey) {
                        Text(
                            model.draft.effectiveName.isEmpty
                                ? String(localized: AppStrings.Settings.derivedFromTheTitle)
                                : model.draft.effectiveName
                        )
                        .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Toggle(
                        AppStrings.Common.enabled.swiftUIKey,
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
                        Text(AppStrings.Settings.anotherSkillAlreadyUsesThisName).foregroundStyle(.orange)
                    }
                    if !model.draft.importedFrom.isEmpty {
                        LabeledContent(AppStrings.Settings.importedFrom.swiftUIKey, value: model.draft.importedFrom)
                    }
                }
                Section(AppStrings.Settings.description.swiftUIKey) {
                    TextEditor(text: $model.draft.summary).frame(minHeight: 90)
                    Text(
                        AppStrings.Settings.skillDescriptionExplanation
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\(model.draft.summary.count)/\(AgentSkill.maximumSummaryCharacters)").font(.caption)
                }
                Section(AppStrings.Settings.instructions.swiftUIKey) {
                    TextEditor(text: $model.draft.body).font(.body.monospaced()).frame(minHeight: 240)
                    Text(AppStrings.Settings.skillBodyExplanation).font(.caption)
                        .foregroundStyle(.secondary)
                    if model.draft.body.utf8.count > AgentSkill.maximumBodyBytes {
                        Text(AppStrings.Settings.longerThan(DataSizeFormat.bytes(AgentSkill.maximumBodyBytes)))
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
                id: "export", title: AppStrings.Common.export, systemImage: "square.and.arrow.up",
                perform: { exporting = true })
        ]
        if library.skill(model.original.id) != nil {
            actions.append(
                MobileEditorToolbarAction(
                    id: "delete", title: AppStrings.Common.delete, systemImage: "trash", role: .destructive,
                    startsGroup: true, perform: delete))
        }
        return actions
    }

    private func delete() {
        library.delete(id: model.original.id)
        if let error = library.storageError { self.error = error } else { dismiss() }
    }
}
