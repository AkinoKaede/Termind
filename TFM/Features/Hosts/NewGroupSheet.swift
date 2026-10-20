// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

/// Make or edit a group without leaving whatever raised the sheet — the
/// companion to `NewIdentitySheet`, and the only place a group is ever edited.
///
/// One sheet for both verbs because they ask the same two questions. Renaming is
/// the common case, but a group that is in the wrong place has nowhere else to be
/// fixed, so an inline rename would have left that field permanently unreachable.
struct NewGroupSheet: View {
    /// `nil` creates; anything else edits that group in place.
    var group: HostGroup?
    var initialParentID: HostGroup.ID?
    let create: (HostGroup) -> Void
    var requestedClose: (() -> Void)?
    var requestedBack: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    @State private var editor: TailscaleGroupEditor?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmsDiscard = false
    @State private var editingToken: UUID?
    @State private var confirmsDeletion = false

    init(
        group: HostGroup? = nil,
        parentID: HostGroup.ID? = nil,
        back: (() -> Void)? = nil,
        create: @escaping (HostGroup) -> Void,
        close: (() -> Void)? = nil
    ) {
        self.group = group
        initialParentID = parentID
        self.create = create
        requestedClose = close
        requestedBack = back
    }

    private var isEditing: Bool { group != nil }

    /// Everything this group could be filed inside — which is every group except
    /// itself and its own descendants, since a group cannot contain itself.
    private var parentCandidates: [HostGroup] {
        guard let group else { return app.hostLibrary.groups }
        let forbidden = Set([group.id] + app.hostLibrary.descendantGroups(of: group.id).map(\.id))
        return app.hostLibrary.groups.filter { !forbidden.contains($0.id) }
    }

    var body: some View {
        VaultDetailScaffold(
            title: isEditing ? AppStrings.Vault.editGroup : AppStrings.Vault.newGroup,
            symbol: "folder.fill", close: cancelEditing,
            closeLabel: requestedClose == nil ? AppStrings.Common.back : AppStrings.Common.close,
            closeSymbol: requestedClose == nil ? "chevron.backward" : "xmark"
        ) {
            form
        } footer: {
            footer
        }
        .onAppear {
            load()
            guard requestedClose != nil else { return }
            editingToken = editingSession.register(
                route: editingRoute, isDirty: { editor?.isDirty == true },
                isBusy: { editor?.isSaving == true }
            ) { await commitChanges() }
        }
        .onDisappear {
            if let editingToken { editingSession.unregister(editingToken) }
            saveTask?.cancel()
            editor?.cancel()
        }
        .confirmationDialog(
            AppStrings.Common.discardChangesConfirmation, isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.keepEditing.swiftUIKey, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(AppStrings.Common.discardChanges.swiftUIKey, role: .destructive, action: close)
        } message: {
            Text(
                isEditing ? AppStrings.Common.discardChangesQuestion : AppStrings.Common.discardNewGroupQuestion)
        }
        .confirmationDialog(
            AppStrings.Common.deleteNamedConfirmation(group?.name ?? ""), isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Vault.deleteGroupAndHosts.swiftUIKey, role: .destructive) { delete(keepHosts: false) }
            Button(AppStrings.Vault.keepHosts.swiftUIKey) { delete(keepHosts: true) }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            if let group {
                Text(
                    AppStrings.Vault.groupDeletionMessage(
                        hostCount: app.hostLibrary.hosts(inTreeOf: group.id).count,
                        nestedGroupCount: app.hostLibrary.descendantGroups(of: group.id).count, locale: locale))
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var form: some View {
        if let editor {
            @Bindable var editor = editor
            Form {
                Section {
                    TextField(
                        AppStrings.Common.name.swiftUIKey, text: $editor.draft.name.singleLineText, axis: .horizontal
                    )
                    .singleLinePaste().lineLimit(1)
                    Picker(AppStrings.Common.inside.swiftUIKey, selection: $editor.draft.parentID) {
                        Text(AppStrings.Common.topLevel).tag(HostGroup.ID?.none)
                        ForEach(parentCandidates) { candidate in
                            Text(candidate.name).tag(HostGroup.ID?.some(candidate.id))
                        }
                    }
                }
                TailscaleGroupFields(editor: editor, requireAccess: { app.proAccess.require(.tailscale) }) { value in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
            .formStyle(.grouped)
            .disabled(editor.isSaving)
            .overlay(alignment: .bottom) { if let saveError { Text(saveError).foregroundStyle(.red) } }
        }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) { confirmsDeletion = true }
                    .disabled(editor?.isSaving == true)
            }
            Spacer()

            Button(AppStrings.Common.cancel.swiftUIKey, action: cancelEditing)
                .keyboardShortcut(.cancelAction)
                .disabled(editor?.isSaving == true)

            Button(AppStrings.Common.save.swiftUIKey, action: saveAndClose)
                .keyboardShortcut(.defaultAction)
                .disabled(editor?.canSave != true)
        }
        .padding(Metrics.Space.l)
    }

    private func close() {
        guard editor?.isSaving != true else { return }
        editor?.cancel()
        if let requestedBack { requestedBack() } else if let requestedClose { requestedClose() } else { dismiss() }
    }

    private func cancelEditing() {
        guard editor?.isSaving != true else { return }
        if requestedClose != nil {
            editingSession.requestCancellation(route: editingRoute, action: close)
        } else if editor?.isDirty == true {
            confirmsDiscard = true
        } else {
            close()
        }
    }

    private var editingRoute: VaultWorkRoute {
        .hostGroupEditor(groupID: group?.id, parentID: initialParentID)
    }

    private func delete(keepHosts: Bool) {
        guard let group, editor?.isSaving != true else { return }
        app.deleteHostGroup(group.id, keepHosts: keepHosts)
        window.pruneVaultSelections(in: app.hostLibrary)
        guard app.hostLibrary.group(group.id) == nil else {
            saveError = app.hostLibrary.storageError
            return
        }
        close()
    }

    private func load() {
        guard editor == nil else { return }
        editor = TailscaleGroupEditor(model: app.tailscale, group: group, parentID: initialParentID)
    }

    private func saveAndClose() {
        guard let editor, editor.canSave else { return }
        saveTask = Task {
            if await commitChanges() { close() }
        }
    }

    private func commitChanges() async -> Bool {
        guard let editor, !editor.isSaving else { return false }
        guard editor.canSave else {
            saveError = String(localized: AppStrings.Common.completeAllRequiredFieldsBeforeSaving)
            return false
        }
        do {
            create(try await editor.save())
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

}

#Preview {
    NewGroupSheet(create: { _ in })
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel())
        .environment(VaultWorkEditingSession())
}
