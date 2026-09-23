import SwiftUI
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

    @State private var name = ""
    @State private var parentID: HostGroup.ID?

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
    }

    // MARK: - Pieces

    private var form: some View {
        Form {
            Section {
                TextField(AppStrings.Common.name.swiftUIKey, text: $name.singleLineText, axis: .horizontal)
                    .singleLinePaste().lineLimit(1)

                // "Inside", not "Parent": the answer is where the group goes,
                // and every other row here is phrased as a property of the
                // group rather than of the tree.
                Picker(AppStrings.Common.inside.swiftUIKey, selection: $parentID) {
                    Text(AppStrings.Common.topLevel).tag(HostGroup.ID?.none)
                    ForEach(parentCandidates) { candidate in
                        Text(candidate.name).tag(HostGroup.ID?.some(candidate.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(AppStrings.Common.cancel.swiftUIKey, action: close)
                .keyboardShortcut(.cancelAction)

            Button(isEditing ? AppStrings.Common.save.swiftUIKey : AppStrings.Common.add.swiftUIKey, action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
        .padding(Metrics.Space.l)
    }

    // MARK: - Adding

    /// A group is nothing but its name, so an unnamed one cannot be made — no
    /// fallback to invent here, unlike a host, which can borrow its address.
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func close() {
        if let requestedBack { requestedBack() } else if let requestedClose { requestedClose() } else { dismiss() }
    }

    private func load() {
        if let group {
            name = group.name
            parentID = group.parentID
        } else {
            parentID = initialParentID
        }
    }

    /// Editing keeps the group's id, `sortIndex`, and expansion state, so
    /// `HostLibraryModel.upsert(_:)` replaces it in place and the section it is drawn as
    /// does not jump or spring open. Creating leaves `sortIndex` at its default,
    /// which the store then numbers against the new group's siblings — knowledge
    /// this sheet does not have.
    private func add() {
        if var edited = group {
            edited.name = trimmedName
            edited.parentID = parentID
            create(edited)
        } else {
            create(HostGroup(name: trimmedName, parentID: parentID))
        }
        close()
    }
}

#Preview {
    NewGroupSheet(create: { _ in })
        .environment(AppModel(hosts: .demo()))
}
