import SwiftUI
import TermindApplication
import TermindDomain

struct MobileCredentialsView: View {
    let app: MobileAppModel
    @State private var editing: Identity?
    @State private var keyEditor: MobileKeyEditorModel?
    @State private var deletingKey: SSHKeyRef?
    @State private var deletingIdentity: Identity?
    @State private var error: String?

    var body: some View {
        List {
            Section("Keys") {
                ForEach(app.credentials.keys) { key in
                    Button {
                        keyEditor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(key.label)
                            Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("Delete", role: .destructive) { deletingKey = key } }
                }
            }
            Section("Identities") {
                ForEach(app.credentials.identities) { identity in
                    Button {
                        editing = identity
                    } label: {
                        VStack(alignment: .leading) {
                            Text(identity.name)
                            Text(identity.username).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deletingIdentity = identity } }
                }
            }
        }
        .navigationTitle("Keychain")
        .toolbar {
            Menu {
                Button("Generate Key") {
                    keyEditor = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
                }
                Button("Import Key") {
                    keyEditor = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
                }
                Divider()
                Button("New Identity") { editing = Identity(name: "", username: "") }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(item: $editing) { MobileIdentityEditor(app: app, identity: $0) }
        .sheet(item: $keyEditor) { MobileKeyEditor(model: $0) }
        .confirmationDialog(
            "Delete Identity?",
            isPresented: Binding(get: { deletingIdentity != nil }, set: { if !$0 { deletingIdentity = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let identity = deletingIdentity, !app.credentials.delete(identityID: identity.id) {
                    error = app.credentials.storageError
                }
                deletingIdentity = nil
            }
        } message: {
            Text("Hosts using this identity will ask for credentials again.")
        }
        .confirmationDialog(
            "Delete Key?", isPresented: Binding(get: { deletingKey != nil }, set: { if !$0 { deletingKey = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let key = deletingKey {
                    do { try app.credentials.delete(keyID: key.id) } catch { self.error = error.localizedDescription }
                }
                deletingKey = nil
            }
        } message: {
            Text("Identities using this key will no longer have access to it.")
        }
        .alert("Unable to Delete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

private struct MobileIdentityEditor: View {
    let app: MobileAppModel
    let original: Identity
    @State private var draft: Identity
    @State private var password = ""
    @State private var removePassword = false

    init(app: MobileAppModel, identity: Identity) {
        self.app = app
        original = identity
        _draft = State(initialValue: identity)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Identity"),
            isDirty: draft != original || !password.isEmpty || removePassword,
            canSave: !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            save: {
                draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if draft.name.isEmpty { draft.name = draft.username }
                try app.library.upsert(
                    draft, passwordUpdate: removePassword ? .remove : password.isEmpty ? .keep : .replace(password))
            },
            content: {
                Section("Identity") {
                    LabeledContent("Name") { TextField("Name", text: $draft.name, prompt: Text(draft.username)) }
                    LabeledContent("Username") {
                        TextField("Username", text: $draft.username).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section {
                    Picker("Color", selection: $draft.colorTag) {
                        ForEach(TagColor.allCases) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                    }
                }
                Section("Authentication") {
                    LabeledContent("Password") {
                        SecureField("Password", text: $password).textContentType(.password).disabled(removePassword)
                    }
                    if original.usesPassword { Toggle("Remove Password", isOn: $removePassword) }
                    Picker("Store password in", selection: $draft.passwordStorage) {
                        Text("This Device").tag(PasswordStorage.thisDevice)
                        Text("iCloud").tag(PasswordStorage.iCloud)
                    }
                    Picker("Key", selection: $draft.keyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(app.credentials.keys) { Text($0.label).tag(Optional($0.id)) }
                    }
                }
            })
    }
}
