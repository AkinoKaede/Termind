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
                MobileCardSection(title: AppStrings.Keychain.keys, count: keys.count) {
                    if app.credentials.keys.isEmpty {
                        ContentUnavailableView(AppStrings.Keychain.noKeys.swiftUIKey, systemImage: "key")
                    }
                    MobileCardGrid {
                        ForEach(keys) { key in
                            MobileActionCard {
                                keyEditor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
                            } content: {
                                MobileKeyCredentialCard(key: key, credentials: app.credentials)
                            } actions: {
                                Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
                                    keyEditor = MobileKeyEditorModel(
                                        mode: .edit, credentials: app.credentials, key: key)
                                }
                                Divider()
                                Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                    deletingKey = key
                                }
                            }
                        }
                    }
                }
            }
            if query.isEmpty || !identities.isEmpty {
                MobileCardSection(title: AppStrings.Keychain.identities, count: identities.count) {
                    if app.credentials.identities.isEmpty {
                        ContentUnavailableView(
                            AppStrings.Keychain.noIdentities.swiftUIKey, systemImage: "person.crop.square")
                    }
                    MobileCardGrid {
                        ForEach(identities) { identity in
                            MobileActionCard {
                                editing = identity
                            } content: {
                                MobileIdentityCredentialCard(identity: identity, credentials: app.credentials)
                            } actions: {
                                Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") { editing = identity }
                                Divider()
                                Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                    deletingIdentity = identity
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query.singleLineText)
        .navigationTitle(AppStrings.Navigation.keychain.swiftUIKey)
        .toolbar {
            Menu {
                Button(AppStrings.Keychain.generateKey.swiftUIKey, systemImage: "key") {
                    keyEditor = MobileKeyEditorModel(
                        mode: .generate, credentials: app.credentials,
                        defaultStorage: app.newVaultKeyStorage)
                }
                Button(AppStrings.Keychain.importKey.swiftUIKey, systemImage: "square.and.arrow.down") {
                    keyEditor = MobileKeyEditorModel(
                        mode: .importKey, credentials: app.credentials,
                        defaultStorage: app.newVaultKeyStorage)
                }
                Divider()
                Button(AppStrings.Keychain.newIdentity.swiftUIKey, systemImage: "person.crop.circle.badge.plus") {
                    editing = Identity(
                        name: "", username: "",
                        passwordStorage: app.newVaultPasswordStorage)
                }
            } label: {
                Label(AppStrings.Common.add.swiftUIKey, systemImage: "plus").labelStyle(.iconOnly)
            }
        }
        .sheet(item: $editing) { MobileIdentityEditor(app: app, identity: $0) }
        .sheet(item: $keyEditor) { MobileKeyEditor(model: $0) }
        .confirmationDialog(
            AppStrings.Keychain.deleteIdentityConfirmation,
            isPresented: Binding(get: { deletingIdentity != nil }, set: { if !$0 { deletingIdentity = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                if let identity = deletingIdentity, !app.credentials.delete(identityID: identity.id) {
                    error = app.credentials.storageError
                }
                deletingIdentity = nil
            }
        } message: {
            Text(AppStrings.Keychain.deleteIdentityWarning)
        }
        .confirmationDialog(
            AppStrings.Keychain.deleteKeyConfirmation,
            isPresented: Binding(get: { deletingKey != nil }, set: { if !$0 { deletingKey = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                if let key = deletingKey {
                    do { try app.credentials.delete(keyID: key.id) } catch { self.error = error.localizedDescription }
                }
                deletingKey = nil
            }
        } message: {
            Text(AppStrings.Keychain.deleteKeyWarning)
        }
        .alert(
            AppStrings.Common.unableToDelete,
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) { error = nil }
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
            MobileCardChip(title: AppStrings.Keychain.passphraseRequired, symbol: "lock.fill")
        }
    }

    @ViewBuilder private var secondaryChips: some View {
        MobileCardChip(text: key.storage.mobileDisplayName, symbol: key.storage.mobileSymbol)
        switch credentials.keyAvailability(for: key) {
        case .missing:
            MobileCardChip(
                title: AppStrings.Keychain.privateKeyMissing, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .failed:
            MobileCardChip(
                title: AppStrings.Keychain.keychainUnavailable, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .available, .notConfigured:
            EmptyView()
        }
    }

    @ViewBuilder private var dependentLabel: some View {
        if dependents > 0 {
            Text(AppStrings.Keychain.identityCount(dependents))
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
                modifiedLabel
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
                MobileCardChip(title: AppStrings.Vault.password, symbol: "lock.fill")
            case .missing:
                MobileCardChip(
                    title: AppStrings.Keychain.passwordMissing, symbol: "exclamationmark.triangle.fill", tint: .orange)
            case .failed:
                MobileCardChip(
                    title: AppStrings.Keychain.passwordUnavailable, symbol: "exclamationmark.triangle.fill",
                    tint: .orange)
            case .notConfigured:
                EmptyView()
            }
            MobileCardChip(
                text: identity.passwordStorage.mobileDisplayName,
                symbol: identity.passwordStorage.mobileSymbol)
        }
        if identity.usesKey {
            if let key {
                MobileCardChip(text: key.label, symbol: "key.fill", tint: key.colorTag.color ?? .accentColor)
            } else {
                MobileCardChip(
                    title: AppStrings.Keychain.keyMissing, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        if !identity.hasSecret {
            MobileCardChip(title: AppStrings.Keychain.noSecret, symbol: "questionmark.circle")
        }
    }

    private var modifiedLabel: some View {
        Text(
            modifiedAt?.formatted(.relative(presentation: .numeric))
                ?? String(localized: AppStrings.SFTP.unknown)
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var modifiedAt: Date? {
        guard let date = credentials.identityModifiedAt(identity.id),
            date > VaultVersion.baselineDate
        else { return nil }
        return date
    }
}

extension PasswordStorage {
    fileprivate var mobileDisplayName: String {
        switch self {
        case .thisDevice: String(localized: AppStrings.Keychain.thisDevice)
        case .iCloud: String(localized: AppStrings.Keychain.iCloud)
        }
    }

    fileprivate var mobileSymbol: String {
        switch self {
        case .thisDevice: "ipad.and.iphone"
        case .iCloud: "icloud.fill"
        }
    }
}

extension KeyStorage {
    fileprivate var mobileDisplayName: String {
        switch self {
        case .thisDevice: String(localized: AppStrings.Keychain.thisDevice)
        case .iCloud: String(localized: AppStrings.Keychain.iCloud)
        case .secureEnclave: String(localized: AppStrings.Keychain.secureEnclave)
        }
    }

    fileprivate var mobileSymbol: String {
        switch self {
        case .thisDevice: "ipad.and.iphone"
        case .iCloud: "icloud.fill"
        case .secureEnclave: "checkmark.shield.fill"
        }
    }
}

nonisolated struct MobileIdentityEditorConfiguration: Hashable, Sendable {
    var showsKey: Bool
    var requiresPassword: Bool

    static let standard = MobileIdentityEditorConfiguration(showsKey: true, requiresPassword: false)
    static let proxy = MobileIdentityEditorConfiguration(showsKey: false, requiresPassword: true)

    func canSave(
        identity: Identity, password: String, hasConfiguredPassword: Bool, removesPassword: Bool
    ) -> Bool {
        guard !identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard requiresPassword else { return true }
        return hasConfiguredPassword || !password.isEmpty
    }
}

struct MobileIdentityEditor: View {
    let app: MobileAppModel
    let original: Identity
    let isNew: Bool
    let configuration: MobileIdentityEditorConfiguration
    let saved: (Identity) -> Void
    @State private var draft: Identity
    @State private var password = ""
    @State private var originalPassword = ""
    @State private var didLoadPassword = false

    init(
        app: MobileAppModel, identity: Identity,
        configuration: MobileIdentityEditorConfiguration = .standard,
        saved: @escaping (Identity) -> Void = { _ in }
    ) {
        self.app = app
        original = identity
        isNew = app.library.identity(identity.id) == nil
        self.configuration = configuration
        self.saved = saved
        _draft = State(initialValue: identity)
    }

    var body: some View {
        MobileEditorSheet(
            title: title,
            isDirty: draft != original || password != originalPassword,
            canSave: configuration.canSave(
                identity: draft, password: password,
                hasConfiguredPassword: original.usesPassword,
                removesPassword: canEditPassword && password.isEmpty && !originalPassword.isEmpty),
            save: {
                draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                try app.library.upsert(
                    draft,
                    passwordUpdate: !canEditPassword
                        ? .keep
                        : password == originalPassword ? .keep : password.isEmpty ? .remove : .replace(password))
                saved(draft)
            },
            content: {
                IdentityFormSections(
                    name: $draft.name, username: $draft.username, password: $password,
                    passwordStorage: $draft.passwordStorage, keyID: $draft.keyID,
                    colorTag: $draft.colorTag, namePrompt: Text(verbatim: draft.defaultName),
                    keys: app.credentials.keys, showsKey: configuration.showsKey,
                    canEditPassword: canEditPassword,
                    canEditPasswordStorage: canEditPassword
                        && !(original.usesPassword && original.passwordStorage == .iCloud)
                )
            }
        )
        .onAppear(perform: loadPasswordOnce)
        .onDisappear {
            password = ""
            originalPassword = ""
        }
    }

    var title: String {
        String(localized: isNew ? AppStrings.Keychain.newIdentity : AppStrings.Keychain.editIdentity)
    }

    private var hasAvailablePassword: Bool {
        original.usesPassword && app.credentials.passwordAvailability(for: original) == .available
    }

    var canEditPassword: Bool {
        !original.usesPassword || hasAvailablePassword
    }

    private func loadPasswordOnce() {
        guard !didLoadPassword else { return }
        didLoadPassword = true
        guard hasAvailablePassword,
            let loaded = try? app.credentials.editablePassword(for: original)
        else { return }
        password = loaded
        originalPassword = loaded
    }
}
