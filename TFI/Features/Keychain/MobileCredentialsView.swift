import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileCredentialsView: View {
    let app: MobileAppModel
    @State private var editing: Identity?
    @State private var keyEditor: MobileKeyEditorModel?
    @State private var deletingKey: SSHKeyRef?
    @State private var deletingIdentity: Identity?
    @State private var error: String?
    @State private var query = ""

    private var keys: [SSHKeyRef] { app.credentials.searchKeys(query) }
    private var identities: [Identity] { app.credentials.searchIdentities(query) }

    init(app: MobileAppModel, initialQuery: String = "") {
        self.app = app
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        MobileCardPage {
            if !query.isEmpty, keys.isEmpty, identities.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            if query.isEmpty || !keys.isEmpty {
                MobileCardSection(title: "Keys", count: keys.count) {
                    if app.credentials.keys.isEmpty {
                        ContentUnavailableView("No Keys", systemImage: "key")
                    }
                    MobileCardGrid {
                        ForEach(keys) { key in
                            MobileActionCard {
                                keyEditor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
                            } content: {
                                MobileKeyCredentialCard(key: key, credentials: app.credentials)
                            } actions: {
                                Button("Edit", systemImage: "pencil") {
                                    keyEditor = MobileKeyEditorModel(
                                        mode: .edit, credentials: app.credentials, key: key)
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) { deletingKey = key }
                            }
                        }
                    }
                }
            }
            if query.isEmpty || !identities.isEmpty {
                MobileCardSection(title: "Identities", count: identities.count) {
                    if app.credentials.identities.isEmpty {
                        ContentUnavailableView("No Identities", systemImage: "person.crop.square")
                    }
                    MobileCardGrid {
                        ForEach(identities) { identity in
                            MobileActionCard {
                                editing = identity
                            } content: {
                                MobileIdentityCredentialCard(identity: identity, credentials: app.credentials)
                            } actions: {
                                Button("Edit", systemImage: "pencil") { editing = identity }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deletingIdentity = identity
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Keychain")
        .toolbar {
            Menu {
                Button("Generate Key", systemImage: "key") {
                    keyEditor = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
                }
                Button("Import Key", systemImage: "square.and.arrow.down") {
                    keyEditor = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
                }
                Divider()
                Button("New Identity", systemImage: "person.crop.circle.badge.plus") {
                    editing = Identity(name: "", username: "")
                }
            } label: {
                Label("Add", systemImage: "plus").labelStyle(.iconOnly)
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

private struct MobileKeyCredentialCard: View {
    let key: SSHKeyRef
    let credentials: CredentialLibraryModel

    private var dependents: Int { credentials.identities(using: key.id).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIcon(symbol: "key.fill", tint: key.colorTag.color ?? .accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(key.label).font(.headline).lineLimit(1)
                    Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                primaryChips
                secondaryChips
                Spacer(minLength: 6)
                dependentLabel
            }
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var primaryChips: some View {
        MobileCardChip(text: keyDisplayName)
        if key.hasPassphrase {
            MobileCardChip(title: "Passphrase Required", symbol: "lock.fill")
        }
    }

    @ViewBuilder private var secondaryChips: some View {
        MobileCardChip(text: key.storage.mobileDisplayName, symbol: key.storage.mobileSymbol)
        switch credentials.keyAvailability(for: key) {
        case .missing:
            MobileCardChip(title: "Private key missing", symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .failed:
            MobileCardChip(title: "Keychain unavailable", symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .available, .notConfigured:
            EmptyView()
        }
    }

    @ViewBuilder private var dependentLabel: some View {
        if dependents > 0 {
            Text("\(dependents) identities")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }

    private var keyDisplayName: String {
        if key.algorithm == .rsa, let bits = key.keySize { return "RSA \(bits)" }
        return key.algorithm.displayName
    }
}

private struct MobileIdentityCredentialCard: View {
    let identity: Identity
    let credentials: CredentialLibraryModel

    private var key: SSHKeyRef? { identity.keyID.flatMap(credentials.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIcon(
                    symbol: "person.badge.key.fill", tint: identity.colorTag.color ?? .accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(identity.name).font(.headline).lineLimit(1)
                    Text(identity.username).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                secretChips
                Spacer(minLength: 6)
                lastUsedLabel
            }
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var secretChips: some View {
        if identity.usesPassword {
            switch credentials.passwordAvailability(for: identity) {
            case .available:
                MobileCardChip(title: "Password", symbol: "lock.fill")
            case .missing:
                MobileCardChip(title: "Password missing", symbol: "exclamationmark.triangle.fill", tint: .orange)
            case .failed:
                MobileCardChip(
                    title: "Password unavailable", symbol: "exclamationmark.triangle.fill", tint: .orange)
            case .notConfigured:
                EmptyView()
            }
        }
        if identity.usesKey {
            if let key {
                MobileCardChip(text: key.label, symbol: "key.fill", tint: key.colorTag.color ?? .accentColor)
            } else {
                MobileCardChip(title: "Key missing", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        if !identity.hasSecret {
            MobileCardChip(title: "No secret", symbol: "questionmark.circle")
        }
    }

    private var lastUsedLabel: some View {
        Text(
            identity.lastUsedAt?.formatted(.relative(presentation: .numeric))
                ?? String(localized: "Never")
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}

extension KeyStorage {
    fileprivate var mobileDisplayName: String {
        switch self {
        case .thisDevice: String(localized: "This Device")
        case .iCloud: String(localized: "iCloud")
        case .secureEnclave: String(localized: "Secure Enclave")
        }
    }

    fileprivate var mobileSymbol: String {
        switch self {
        case .thisDevice: "lock.fill"
        case .iCloud: "icloud.fill"
        case .secureEnclave: "checkmark.shield.fill"
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
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.name, prompt: Text(draft.username))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Username") {
                        TextField("Username", text: $draft.username).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                        ColorTagPicker(selection: $draft.colorTag, layout: .touch)
                    }
                }
                Section("Authentication") {
                    LabeledContent("Password") {
                        SecureField("Password", text: $password).textContentType(.password)
                            .multilineTextAlignment(.trailing).disabled(removePassword)
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
