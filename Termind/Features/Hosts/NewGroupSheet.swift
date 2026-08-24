import SwiftUI

/// Make or edit a group without leaving whatever raised the sheet — the
/// companion to `NewIdentitySheet`, and the only place a group is ever edited.
///
/// One sheet for both verbs because they ask the same two questions. Renaming is
/// the common case, but a group that is in the wrong place has nowhere else to be
/// fixed, so an inline rename would have left that field permanently unreachable.
struct NewGroupSheet: View {
    /// `nil` creates; anything else edits that group in place.
    var group: HostGroup?
    let create: (HostGroup) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var parentID: HostGroup.ID?

    private var isEditing: Bool { group != nil }

    /// Everything this group could be filed inside — which is every group except
    /// itself and its own descendants, since a group cannot contain itself.
    private var parentCandidates: [HostGroup] {
        guard let group else { return app.hosts.groups }
        let forbidden = Set([group.id] + app.hosts.descendantGroups(of: group.id).map(\.id))
        return app.hosts.groups.filter { !forbidden.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: Metrics.CreateSheet.width)
        .onAppear(perform: load)
    }

    // MARK: - Pieces

    private var header: some View {
        Label(isEditing ? "Edit Group" : "New Group", systemImage: "folder.fill")
            .font(.headline)
            .labelStyle(.titleOnly)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.Space.xl)
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)

                // "Inside", not "Parent": the answer is where the group goes,
                // and every other row here is phrased as a property of the
                // group rather than of the tree.
                Picker("Inside", selection: $parentID) {
                    Text("Top Level").tag(HostGroup.ID?.none)
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

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(isEditing ? "Save" : "Add", action: add)
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

    private func load() {
        guard let group else { return }
        name = group.name
        parentID = group.parentID
    }

    /// Editing keeps the group's id, `sortIndex`, and expansion state, so
    /// `HostStore.upsert(_:)` replaces it in place and the section it is drawn as
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
        dismiss()
    }
}

#Preview {
    NewGroupSheet { _ in }
        .environment(AppModel(hosts: .demo()))
}
