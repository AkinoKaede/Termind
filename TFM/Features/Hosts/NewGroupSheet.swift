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
    @Environment(\.dismiss) private var dismiss

    @State private var editor: TailscaleGroupEditor?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

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
            symbol: "folder.fill", close: close,
            closeLabel: requestedClose == nil ? AppStrings.Common.back : AppStrings.Common.close,
            closeSymbol: requestedClose == nil ? "chevron.backward" : "xmark"
        ) {
            form
        } footer: {
            footer
        }
        .onAppear(perform: load)
        .onDisappear {
            saveTask?.cancel()
            editor?.cancel()
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
            Spacer()

            Button(AppStrings.Common.cancel.swiftUIKey, action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(editor?.isSaving == true)

            Button(isEditing ? AppStrings.Common.save.swiftUIKey : AppStrings.Common.add.swiftUIKey, action: add)
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

    private func load() {
        guard editor == nil else { return }
        editor = TailscaleGroupEditor(model: app.tailscale, group: group, parentID: initialParentID)
    }

    private func add() {
        guard let editor, editor.canSave else { return }
        saveTask = Task {
            do {
                let saved = try await editor.save()
                create(saved)
                close()
            } catch { saveError = error.localizedDescription }
        }
    }

}

#Preview {
    NewGroupSheet(create: { _ in })
        .environment(AppModel(hosts: .demo()))
}
