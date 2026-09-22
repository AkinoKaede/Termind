import SwiftUI
import TermindDomain
import TermindPresentation

/// Controls which parts of the shared Identity editor are visible and which
/// credentials are mandatory for the context that raised it.
nonisolated struct IdentityEditorConfiguration: Hashable, Sendable {
    var newTitle: String
    var editTitle: String
    var showsName: Bool
    var showsKey: Bool
    var requiresPassword: Bool

    static let standard = IdentityEditorConfiguration(
        newTitle: String(localized: "New Identity"),
        editTitle: String(localized: "Edit Identity"),
        showsName: true, showsKey: true, requiresPassword: false
    )

    static let proxy = IdentityEditorConfiguration(
        newTitle: String(localized: "New Identity"),
        editTitle: String(localized: "Edit Identity"),
        showsName: true, showsKey: false, requiresPassword: true
    )

    func accepts(
        username: String, password: String,
        hasConfiguredPassword: Bool, removesPassword: Bool
    ) -> Bool {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard requiresPassword else { return true }
        return hasConfiguredPassword || !password.isEmpty
    }
}

/// Make an identity without leaving whatever raised the sheet.
///
/// Lives here rather than beside the host editor because three places need it:
/// the Identity picker in the host editor, the Keychain page's toolbar, and that
/// page's New Identity tile. Sending someone to a different page to make the
/// thing a picker is asking them for is how a half-filled form gets abandoned.
///
/// The sheet hands the finished value back through `create` instead of writing
/// to the store itself. The caller is the one that knows what to do next —
/// select it in a picker, highlight it as a card — and it cannot do that if the
/// only record of what was made is a row that appeared somewhere in an array.
///
/// Password and key are separate, optional, and not exclusive — a login often
/// has both, and the identity is allowed to have neither and be finished later.
///
/// The password never travels inside the `Identity`. It is handed to `create`
/// alongside it, so the caller stores the two in the places they belong: the
/// record in SwiftData, the secret in Keychain.
struct NewIdentitySheet: View {
    let existing: Identity?
    let configuration: IdentityEditorConfiguration
    let initialPasswordStorage: PasswordStorage
    let create: (Identity, IdentityPasswordUpdate) throws -> Void
    var requestedClose: (() -> Void)?
    var requestedBack: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var username: String
    @State private var password = ""
    @State private var originalPassword = ""
    @State private var passwordStorage: PasswordStorage
    @State private var keyID: SSHKeyRef.ID?
    @State private var colorTag: TagColor
    @State private var saveError: String?
    @State private var didLoadPassword = false
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?

    init(
        identity: Identity? = nil,
        configuration: IdentityEditorConfiguration = .standard,
        defaultPasswordStorage: PasswordStorage = .iCloud,
        back: (() -> Void)? = nil,
        create: @escaping (Identity, IdentityPasswordUpdate) throws -> Void,
        close: (() -> Void)? = nil
    ) {
        existing = identity
        self.configuration = configuration
        initialPasswordStorage = identity?.passwordStorage ?? defaultPasswordStorage
        self.create = create
        requestedClose = close
        requestedBack = back
        _name = State(initialValue: identity?.name ?? "")
        _username = State(initialValue: identity?.username ?? "")
        _passwordStorage = State(initialValue: identity?.passwordStorage ?? defaultPasswordStorage)
        _keyID = State(initialValue: identity?.keyID)
        _colorTag = State(initialValue: identity?.colorTag ?? .none)
    }

    var body: some View {
        VaultDetailScaffold(
            title: LocalizedStringKey(existing == nil ? configuration.newTitle : configuration.editTitle),
            symbol: "person.badge.key.fill",
            close: {
                if requestedClose == nil { close() } else { cancelEditing() }
            },
            closeLabel: requestedClose == nil ? "Back" : "Cancel",
            closeSymbol: requestedClose == nil ? "chevron.backward" : "xmark"
        ) {
            form
        } footer: {
            footer
        }
        .onAppear {
            loadPasswordOnce()
            guard requestedClose != nil else { return }
            editingToken = editingSession.register(
                route: .identityEditor(existing?.id), isDirty: { isDirty }
            ) { commitChanges() }
        }
        .onDisappear {
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog("Delete Identity?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Identity", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hosts using this identity will ask for credentials again.")
        }
    }

    // MARK: - Pieces

    private var form: some View {
        Form {
            // Password and key are both optional and may be used together.
            IdentityFormSections(
                name: $name, username: $username, password: $password,
                passwordStorage: $passwordStorage, keyID: $keyID, colorTag: $colorTag,
                namePrompt: Text(verbatim: Identity.defaultName(username: username)),
                keys: app.credentials.keys, showsName: configuration.showsName,
                showsKey: configuration.showsKey, canEditPassword: canEditPassword,
                canEditPasswordStorage: canEditPassword
                    && !(existing?.usesPassword == true && existing?.passwordStorage == .iCloud)
            )
        }
        .formStyle(.grouped)
        .onDisappear {
            password = ""
            originalPassword = ""
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            if existing != nil, requestedClose != nil {
                Button("Delete", role: .destructive) { confirmsDeletion = true }
            }
            Spacer()
            Button("Cancel") {
                if requestedClose == nil { close() } else { cancelEditing() }
            }
            Button("Save", action: saveAndClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(Metrics.Space.l)
        .overlay(alignment: .leading) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Adding

    /// The username is the one thing that cannot be guessed — a name can fall
    /// back to it, a secret defaults to a password.
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespaces)
    }

    private var hasAvailablePassword: Bool {
        guard let existing else { return false }
        return app.credentials.passwordAvailability(for: existing) == .available
    }

    var canEditPassword: Bool {
        guard let existing, existing.usesPassword else { return true }
        return hasAvailablePassword
    }

    private var passwordUpdate: IdentityPasswordUpdate {
        if !canEditPassword { return .keep }
        if password == originalPassword { return .keep }
        if password.isEmpty { return .remove }
        return .replace(password)
    }

    private func close() {
        if let requestedBack { requestedBack() } else if let requestedClose { requestedClose() } else { dismiss() }
    }

    private var isValid: Bool {
        configuration.accepts(
            username: username, password: password,
            hasConfiguredPassword: existing?.usesPassword == true,
            removesPassword: canEditPassword && password.isEmpty && !originalPassword.isEmpty
        )
    }

    private var isDirty: Bool {
        name != (existing?.name ?? "") || username != (existing?.username ?? "")
            || password != originalPassword
            || passwordStorage != initialPasswordStorage
            || keyID != existing?.keyID || colorTag != (existing?.colorTag ?? .none)
    }

    private func loadPasswordOnce() {
        guard !didLoadPassword else { return }
        didLoadPassword = true
        guard let existing, hasAvailablePassword,
            let loaded = try? app.credentials.editablePassword(for: existing)
        else { return }
        password = loaded
        originalPassword = loaded
    }

    /// The view describes the password change but never mints or changes a
    /// Keychain reference. `HostLibraryModel` owns that transaction so clearing an
    /// existing password cannot strand its old Keychain item.
    private func commitChanges() -> Bool {
        guard isDirty else { return true }
        guard isValid else {
            saveError = String(localized: "Complete all required fields before saving.")
            return false
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = Identity(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            username: trimmedUsername,
            credentialRef: existing?.credentialRef ?? "",
            passwordStorage: passwordStorage,
            keyID: configuration.showsKey ? keyID : nil,
            notes: existing?.notes ?? "",
            colorTag: colorTag
        )
        do {
            try create(identity, passwordUpdate)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func cancelEditing() {
        editingSession.requestTransition(route: .identityEditor(existing?.id), action: close)
    }

    private func saveAndClose() {
        guard commitChanges() else { return }
        close()
    }

    private func delete() {
        guard let existing else { return }
        guard app.credentials.delete(identityID: existing.id) else {
            saveError = app.credentials.storageError ?? String(localized: "The identity could not be deleted.")
            return
        }
        window.pruneVaultSelections(in: app.credentials)
        close()
    }
}

#Preview {
    NewIdentitySheet { _, _ in }
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel())
        .environment(VaultWorkEditingSession())
}
