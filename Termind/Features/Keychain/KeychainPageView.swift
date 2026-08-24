import SwiftUI
import UniformTypeIdentifiers

struct KeyExportRequest: Identifiable {
    let id = UUID()
    let keys: [SSHKeyRef]
}

@Observable
final class KeychainPageState {
    enum SheetRoute: Identifiable {
        case newIdentity
        case generateKey
        case importKey(PendingKeyImport)
        case renameKey(SSHKeyRef)
        case export(KeyExportRequest)
        case editIdentity(Identity)

        var id: String {
            switch self {
            case .newIdentity: "new-identity"
            case .generateKey: "generate-key"
            case .importKey(let pending): "import-key-\(pending.id)"
            case .renameKey(let key): "rename-key-\(key.id)"
            case .export(let request): "export-\(request.id)"
            case .editIdentity(let identity): "edit-identity-\(identity.id)"
            }
        }
    }

    var query = ""
    var sheet: SheetRoute?
    var isImportingFile = false
    var errorMessage: String?
}

/// Everything Termind knows about how you prove who you are — in two parts.
///
/// **Keys** are key pairs: a label, an algorithm, a fingerprint, and a Keychain
/// reference. **Identities** are what a connection actually uses: a username plus
/// either one of those keys or a password. The split exists because the two are
/// not one-to-one — one key signs for `deploy` on the web tier and `postgres` on
/// the database box, and copying the key twice to say that would be a lie about
/// how many keys you have.
///
/// The private half of a key is never loaded into this process's view layer,
/// which is why there is no "reveal" action anywhere on this page and why the
/// footnote says so out loud.
struct KeychainPageView: ManagedCardPage {
    nonisolated enum SectionID: Hashable {
        case keys
        case identities
    }

    nonisolated enum Item: Identifiable, Hashable, Sendable {
        case key(SSHKeyRef)
        case identity(Identity)

        var id: ContextPanelDetailID {
            switch self {
            case .key(let key): .key(key.id)
            case .identity(let identity): .identity(identity.id)
            }
        }

        var key: SSHKeyRef? {
            if case .key(let key) = self { return key }
            return nil
        }

        var identity: Identity? {
            if case .identity(let identity) = self { return identity }
            return nil
        }
    }
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var state = KeychainPageState()

    private var keys: [SSHKeyRef] { app.hosts.searchKeys(state.query) }
    private var identities: [Identity] { app.hosts.searchIdentities(state.query) }

    private var selection: Set<ContextPanelDetailID> {
        Set(window.detailSelection(for: .keychain))
    }

    private var isEmpty: Bool {
        app.hosts.keys.isEmpty && app.hosts.identities.isEmpty
    }

    // MARK: - Page

    var managedSections: [ManagedCardSection<SectionID, Item>] {
        [
            ManagedCardSection(
                id: .keys, title: String(localized: "Keys"),
                items: keys.map(Item.key), showsWhenEmpty: state.query.isEmpty
            ),
            ManagedCardSection(
                id: .identities, title: String(localized: "Identities"),
                items: identities.map(Item.identity), showsWhenEmpty: state.query.isEmpty
            ),
        ]
    }

    var managedSelection: ManagedCardSelection<ContextPanelDetailID> {
        ManagedCardSelection(selected: { selection }, update: setSelection)
    }

    var managedCapabilities: ManagedCardCapabilities<SectionID, ContextPanelDetailID> {
        ManagedCardCapabilities(
            selection: .multiple,
            marqueeSelection: true,
            reordering: ManagedCardReordering(
                isEnabled: state.query.isEmpty,
                dropPolicy: .sameSection
            ) { ids, destination, next in
                switch destination {
                case .keys:
                    let keyIDs = ids.compactMap(\.keyID)
                    app.hosts.move(keyIDs: keyIDs, before: next?.keyID)
                case .identities:
                    let identityIDs = ids.compactMap(\.identityID)
                    app.hosts.move(identityIDs: identityIDs, before: next?.identityID)
                }
            }
        )
    }

    var isManagedSourceEmpty: Bool { isEmpty }

    var showsManagedFootnote: Bool { true }

    func managedHeader(
        for section: ManagedCardSection<SectionID, Item>, isDropTarget: Bool
    ) -> some View {
        CardSectionHeader(
            title: section.title, count: section.items.count,
            isDropTarget: isDropTarget
        )
    }

    @ViewBuilder
    func managedCard(
        for item: Item, context: ManagedCardItemContext<Item>
    ) -> some View {
        switch item {
        case .key(let key):
            KeyCard(
                key: key,
                isSelected: context.isSelected,
                select: context.select,
                extendSelection: context.extendSelection,
                actionKeys: context.actionItems.compactMap(\.key),
                actionIdentities: context.actionItems.compactMap(\.identity),
                rename: { state.sheet = .renameKey(key) },
                export: { requestExport(context.actionItems.compactMap(\.key)) },
                delete: {
                    delete(
                        keys: context.actionItems.compactMap(\.key),
                        identities: context.actionItems.compactMap(\.identity)
                    )
                }
            )
        case .identity(let identity):
            IdentityCard(
                identity: identity,
                isSelected: context.isSelected,
                select: context.select,
                extendSelection: context.extendSelection,
                actionKeys: context.actionItems.compactMap(\.key),
                actionIdentities: context.actionItems.compactMap(\.identity),
                edit: { state.sheet = .editIdentity(identity) },
                delete: {
                    delete(
                        keys: context.actionItems.compactMap(\.key),
                        identities: context.actionItems.compactMap(\.identity)
                    )
                }
            )
        }
    }

    @ViewBuilder
    func managedGhost(for item: Item) -> some View {
        switch item {
        case .key(let key):
            KeyCard(
                key: key, isSelected: false, select: {}, extendSelection: {},
                actionKeys: [], actionIdentities: [], rename: {}, export: {}, delete: {}
            )
            .allowsHitTesting(false)
        case .identity(let identity):
            IdentityCard(
                identity: identity, isSelected: false, select: {}, extendSelection: {},
                actionKeys: [], actionIdentities: [], edit: {}, delete: {}
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func managedSupplementaryContent(for section: SectionID) -> some View {
        switch section {
        case .keys:
            AddCardTile(title: "Import Key") { state.isImportingFile = true }
        case .identities:
            AddCardTile(title: "New Identity") { state.sheet = .newIdentity }
        }
    }

    // MARK: - Selection

    private func setSelection(_ selected: Set<ContextPanelDetailID>) {
        let ordered: [ContextPanelDetailID] =
            keys.compactMap { selected.contains(.key($0.id)) ? .key($0.id) : nil }
            + identities.compactMap {
                selected.contains(.identity($0.id)) ? .identity($0.id) : nil
            }
        window.setDetailSelection(ordered, for: .keychain)
    }

    private func select(_ item: ContextPanelDetailID) {
        window.selectDetail(item, on: .keychain)
    }

    private func requestExport(_ keys: [SSHKeyRef]) {
        guard !keys.isEmpty else { return }
        state.sheet = .export(KeyExportRequest(keys: keys))
    }

    /// Identities go first so deleting a mixed selection never leaves a host
    /// pointing at an identity whose key was removed moments earlier. Keychain
    /// failures leave that key selected and report the first error.
    private func delete(keys: [SSHKeyRef], identities: [Identity]) {
        for identity in identities {
            if !app.hosts.delete(identityID: identity.id) {
                state.errorMessage = app.hosts.storageError
                    ?? String(localized: "The identity could not be deleted.")
            }
        }
        for key in keys {
            do {
                try app.hosts.delete(keyID: key.id)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
        window.pruneDetailSelections(in: app.hosts)
    }

    // MARK: - Chrome

    func managedToolbar() -> some View {
        PageToolbar(
            query: Binding(get: { state.query }, set: { state.query = $0 }),
            prompt: "Filter keys and identities"
        ) {
            Button("Import Key") { state.isImportingFile = true }
            Button("Generate Key") { state.sheet = .generateKey }
            Button("New Identity") { state.sheet = .newIdentity }
        }
    }

    func managedFootnote() -> some View {
        PageFootnote(
            text:
                "Private keys and passwords stay in the Keychain. Termind stores only labels, fingerprints, and references."
        ) {
            EmptyView()
        }
    }

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("Keychain Is Empty", systemImage: "key.fill")
        } description: {
            Text(
                "Import or generate a key, then create an identity with a username. Private keys stay in the Keychain."
            )
        } actions: {
            // The only door out of the empty state that opens yet: an identity
            // can be a username and a password, which needs no key material.
            Button("New Identity") { state.sheet = .newIdentity }
            Button("Import Key") { state.isImportingFile = true }
            Button("Generate Key") { state.sheet = .generateKey }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func managedNoResultsState() -> some View {
        ContentUnavailableView.search(text: state.query)
    }

    var managedPresentation: KeychainPagePresentation {
        KeychainPagePresentation(
            state: state,
            actions: KeychainPagePresentation.Actions(
                saveIdentity: { identity, passwordUpdate in
                    try app.hosts.upsert(identity, passwordUpdate: passwordUpdate)
                    select(.identity(identity.id))
                },
                generate: { label, generation, passphrase, cipher, rounds, savePassphrase, storage, presence in
                    generateKey(
                        label: label, generation: generation, passphrase: passphrase,
                        cipher: cipher, rounds: rounds, savePassphrase: savePassphrase,
                        storage: storage, requiresUserPresence: presence
                    )
                },
                importKey: { pending, label, passphrase, savePassphrase, storage in
                    importKey(
                        pending, label: label, passphrase: passphrase,
                        savePassphrase: savePassphrase, storage: storage
                    )
                },
                renameKey: { key, label in
                    var updated = key
                    updated.label = label
                    do {
                        try app.hosts.upsert(updated)
                        select(.key(updated.id))
                    } catch {
                        state.errorMessage = error.localizedDescription
                    }
                },
                receiveImportedFiles: receiveImportedFiles,
                pruneSelection: { window.pruneDetailSelections(in: app.hosts) }
            )
        )
    }

    private func generateKey(
        label: String, generation: SSHKeyMaterial.Generation, passphrase: String?,
        cipher: SSHKeyMaterial.Cipher, rounds: Int, savePassphrase: Bool,
        storage: KeyStorage, requiresUserPresence: Bool
    ) {
        let comment = "termind@\(ProcessInfo.processInfo.hostName)"
        Task {
            do {
                if storage == .secureEnclave {
                    let material = try await Task.detached(priority: .userInitiated) {
                        try SecureEnclaveKey.generate(
                            comment: comment, requiresUserPresence: requiresUserPresence
                        )
                    }.value
                    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = SSHKeyRef(
                        label: trimmedLabel.isEmpty ? "Secure Enclave" : trimmedLabel,
                        algorithm: .ecdsa256,
                        publicKey: material.publicKey, fingerprint: material.fingerprint,
                        credentialRef: "termind.key.\(UUID().uuidString)",
                        storage: .secureEnclave, keySize: 256, hasPassphrase: false,
                        storesPassphrase: false,
                        requiresUserPresence: requiresUserPresence, createdAt: Date()
                    )
                    try app.hosts.upsert(key, credential: .secureEnclave(material.credential))
                    select(.key(key.id))
                    return
                }
                let material = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyMaterial.generate(
                        generation, comment: comment, passphrase: passphrase,
                        cipher: cipher, rounds: rounds
                    )
                }.value
                let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = SSHKeyRef(
                    label: trimmedLabel.isEmpty ? material.algorithm.typeName : trimmedLabel,
                    algorithm: material.algorithm,
                    publicKey: material.publicKey, fingerprint: material.fingerprint,
                    credentialRef: "termind.key.\(UUID().uuidString)",
                    storage: storage, keySize: material.keySize,
                    hasPassphrase: passphrase != nil,
                    storesPassphrase: passphrase != nil && savePassphrase,
                    createdAt: Date()
                )
                try app.hosts.upsert(
                    key,
                    credential: .software(
                        SSHPrivateKeySecret(
                            privateKey: material.privateKey,
                            passphrase: savePassphrase ? passphrase : nil
                        )
                    )
                )
                select(.key(key.id))
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func receiveImportedFiles(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let privateKey = try String(contentsOf: url, encoding: .utf8)
            guard privateKey.contains("PRIVATE KEY") else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "Select an OpenSSH or PEM private key.")
                    ])
            }
            state.sheet = .importKey(
                PendingKeyImport(
                    label: url.deletingPathExtension().lastPathComponent,
                    privateKey: privateKey
                )
            )
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func importKey(
        _ pending: PendingKeyImport, label: String, passphrase: String?,
        savePassphrase: Bool, storage: KeyStorage
    ) {
        let privateKey = pending.privateKey
        state.sheet = nil
        Task {
            do {
                let material = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyMaterial.inspect(
                        privateKey: privateKey, passphrase: passphrase, comment: label
                    )
                }.value
                let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = SSHKeyRef(
                    label: trimmedLabel.isEmpty ? material.algorithm.typeName : trimmedLabel,
                    algorithm: material.algorithm,
                    publicKey: material.publicKey, fingerprint: material.fingerprint,
                    credentialRef: "termind.key.\(UUID().uuidString)",
                    storage: storage, keySize: material.keySize,
                    hasPassphrase: passphrase != nil,
                    storesPassphrase: passphrase != nil && savePassphrase,
                    createdAt: Date()
                )
                try app.hosts.upsert(
                    key,
                    credential: .software(
                        SSHPrivateKeySecret(
                            privateKey: privateKey,
                            passphrase: savePassphrase ? passphrase : nil
                        )
                    )
                )
                select(.key(key.id))
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

}

struct KeychainPagePresentation: ManagedCardPresentationModifier {
    typealias GenerateAction = (
        String, SSHKeyMaterial.Generation, String?, SSHKeyMaterial.Cipher, Int, Bool,
        KeyStorage, Bool
    ) -> Void
    typealias ImportAction = (PendingKeyImport, String, String?, Bool, KeyStorage) -> Void

    struct Actions {
        let saveIdentity: (Identity, IdentityPasswordUpdate) throws -> Void
        let generate: GenerateAction
        let importKey: ImportAction
        let renameKey: (SSHKeyRef, String) -> Void
        let receiveImportedFiles: (Result<[URL], any Error>) -> Void
        let pruneSelection: () -> Void
    }

    let state: KeychainPageState
    let actions: Actions

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
            .sheet(item: $state.sheet, content: sheetContent)
            .fileImporter(
                isPresented: $state.isImportingFile,
                allowedContentTypes: [.data, .plainText],
                allowsMultipleSelection: false,
                onCompletion: actions.receiveImportedFiles
            )
            .alert(
                "Key Error",
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .onAppear(perform: actions.pruneSelection)
    }

    @ViewBuilder
    private func sheetContent(_ route: KeychainPageState.SheetRoute) -> some View {
        switch route {
        case .newIdentity:
            NewIdentitySheet(create: actions.saveIdentity)
        case .generateKey:
            GenerateKeySheet(generate: actions.generate)
        case .importKey(let pending):
            KeyImportSheet(pending: pending) { label, passphrase, saves, storage in
                actions.importKey(pending, label, passphrase, saves, storage)
            }
        case .renameKey(let key):
            RenameKeySheet(key: key) { actions.renameKey(key, $0) }
        case .export(let request):
            ExportKeyToHostsSheet(keys: request.keys)
        case .editIdentity(let identity):
            NewIdentitySheet(identity: identity, create: actions.saveIdentity)
        }
    }
}

struct PendingKeyImport: Identifiable {
    let id = UUID()
    var label: String
    var privateKey: String
}

private struct KeyImportSheet: View {
    let pending: PendingKeyImport
    let save: (String, String?, Bool, KeyStorage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var storage = KeyStorage.localKeychain
    @State private var passphrase = ""
    @State private var savePassphrase = false

    private let availableStorage: [KeyStorage] = [
        .localKeychain,
        .iCloudKeychain,
    ]

    init(
        pending: PendingKeyImport,
        save: @escaping (String, String?, Bool, KeyStorage) -> Void
    ) {
        self.pending = pending
        self.save = save
        _label = State(initialValue: pending.label)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $label, prompt: Text("Defaults to key type"))
                Picker("Store in", selection: $storage) {
                    ForEach(availableStorage) { location in
                        Text(location.displayName).tag(location)
                    }
                }
                SecureField("Passphrase", text: $passphrase, prompt: Text("If protected"))
                Toggle("Save passphrase", isOn: $savePassphrase)
                    .disabled(passphrase.isEmpty)
                    .onChange(of: passphrase) { _, value in
                        if value.isEmpty { savePassphrase = false }
                    }
                Text(
                    "Choose a private-key file. Termind derives its public key and fingerprint. If you don't save the passphrase, Termind asks for it when needed."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    save(
                        label, passphrase.isEmpty ? nil : passphrase,
                        savePassphrase, storage
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: Metrics.CreateSheet.width)
    }
}

private struct GenerateKeySheet: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case ed25519 = "Ed25519"
        case ecdsa = "ECDSA"
        case rsa = "RSA"

        var id: String { rawValue }
    }

    let generate:
        (
            String, SSHKeyMaterial.Generation, String?, SSHKeyMaterial.Cipher, Int, Bool,
            KeyStorage, Bool
        ) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var storage = KeyStorage.localKeychain
    @State private var kind = Kind.ed25519
    @State private var curveBits = 256
    @State private var rsaBits = 3072
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var cipher = SSHKeyMaterial.Cipher.aes256
    @State private var rounds = 100
    @State private var savePassphrase = false
    @State private var requiresUserPresence = false

    private let availableStorage: [KeyStorage] = [
        .localKeychain,
        .iCloudKeychain,
        .secureEnclave,
    ]

    private var generation: SSHKeyMaterial.Generation {
        if storage == .secureEnclave { return .ecdsa(bits: 256) }
        return switch kind {
        case .ed25519: .ed25519
        case .ecdsa: .ecdsa(bits: curveBits)
        case .rsa: .rsa(bits: rsaBits)
        }
    }

    private var passwordsMatch: Bool {
        passphrase.isEmpty || passphrase == confirmation
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $label, prompt: Text(defaultName))
                Picker("Store in", selection: $storage) {
                    ForEach(availableStorage) { location in
                        Text(location.displayName)
                            .tag(location)
                            .disabled(location == .secureEnclave && !SecureEnclaveKey.isAvailable)
                    }
                }
                if storage == .secureEnclave {
                    LabeledContent("Algorithm", value: "ECDSA")
                    LabeledContent("Elliptic curve", value: "NIST P-256")
                    Toggle("Require authentication", isOn: $requiresUserPresence)
                    Text(
                        "The private key cannot leave the Secure Enclave. Authentication uses Touch ID or this Mac's password when required."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Picker("Algorithm", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if kind == .ecdsa {
                        Picker("Elliptic curve", selection: $curveBits) {
                            Text("NIST P-256").tag(256)
                            Text("NIST P-384").tag(384)
                            Text("NIST P-521").tag(521)
                        }
                    } else if kind == .rsa {
                        Picker("Key size", selection: $rsaBits) {
                            Text("2048 bit").tag(2048)
                            Text("3072 bit").tag(3072)
                            Text("4096 bit").tag(4096)
                        }
                    }
                    SecureField("Passphrase", text: $passphrase, prompt: Text("Optional"))
                        .onChange(of: passphrase) { _, value in
                            if value.isEmpty { savePassphrase = false }
                        }
                    SecureField("Confirm passphrase", text: $confirmation)
                        .disabled(passphrase.isEmpty)
                    if !passphrase.isEmpty {
                        Picker("Cipher", selection: $cipher) {
                            ForEach(SSHKeyMaterial.Cipher.allCases) { cipher in
                                Text(cipher.displayName).tag(cipher)
                            }
                        }
                        TextField("Rounds", value: $rounds, format: .number)
                        Toggle("Save passphrase", isOn: $savePassphrase)
                    }
                    if !passwordsMatch {
                        Text("Passphrases do not match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(
                        passphrase.isEmpty || savePassphrase
                            ? "The generated private key is stored on this Mac."
                            : "The private key is stored on this Mac. Termind asks for its passphrase when needed."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate") {
                    generate(
                        resolvedLabel,
                        generation,
                        storage == .secureEnclave || passphrase.isEmpty ? nil : passphrase,
                        cipher, rounds, savePassphrase,
                        storage, storage == .secureEnclave && requiresUserPresence
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    (storage != .secureEnclave && (!passwordsMatch || (!passphrase.isEmpty && rounds <= 0)))
                        || (storage == .secureEnclave && !SecureEnclaveKey.isAvailable)
                )
            }
            .padding()
        }
        .frame(width: Metrics.CreateSheet.width)
    }

    private var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private var defaultName: String {
        storage == .secureEnclave ? "Secure Enclave" : kind.rawValue
    }
}

struct RenameKeySheet: View {
    let key: SSHKeyRef
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String

    init(key: SSHKeyRef, save: @escaping (String) -> Void) {
        self.key = key
        self.save = save
        _label = State(initialValue: key.label)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $label)
                Text(key.fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(label.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: Metrics.CreateSheet.width)
    }
}

// MARK: - Export to hosts

/// Installs one or more public keys on several saved destinations. A checked row is an
/// explicit authorization to change that account's `authorized_keys`; opening
/// the sheet never inherits the Keychain card selection as a host selection.
struct ExportKeyToHostsSheet: View {
    private enum ExportState: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    let keys: [SSHKeyRef]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var chooser = ManagedChooserState<Host.ID>(mode: .multiple)
    @State private var states: [Host.ID: ExportState] = [:]
    @FocusState private var searchFocused: Bool

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        Binding(get: { chooser.query }, set: { chooser.query = $0 })
    }
    private var hosts: [Host] { app.hosts.searchHosts(query) }
    private var eligibleHosts: [Host] {
        hosts.filter { app.hosts.keyExportUnavailableReason(for: $0) == nil }
    }
    private var isExporting: Bool { states.values.contains(.running) }
    private var isFinished: Bool { !states.isEmpty && !isExporting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 500, height: 460)
        .onAppear { searchFocused = true }
        .onChange(of: chooser.query) {
            chooser.queryDidChange(
                visible: hosts.map(\.id), enabled: Set(eligibleHosts.map(\.id))
            )
        }
        .interactiveDismissDisabled(isExporting)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.m) {
                CardIcon(symbol: "key.fill", tint: .orange)
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text("Export to Hosts")
                        .font(.headline)
                    Text(keySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Metrics.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search hosts", text: queryBinding)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { moveCursor(-1) }
                    .onKeyPress(.downArrow) { moveCursor(1) }
                    .onKeyPress(.space) { toggleCursor() }
                if !query.isEmpty {
                    Button {
                        chooser.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
            .padding(Metrics.Space.s)
            .background(
                .quaternary.opacity(0.5),
                in: .rect(cornerRadius: Metrics.Radius.medium)
            )
        }
        .padding(Metrics.Space.xl)
    }

    @ViewBuilder
    private var content: some View {
        if app.hosts.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add and connect to a host before exporting a key to it.")
            }
        } else if hosts.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(spacing: Metrics.Space.xxs) {
                    ForEach(hosts) { host in
                        row(for: host)
                    }
                }
                .padding(.horizontal, Metrics.Space.l)
                .padding(.vertical, Metrics.Space.s)
            }
        }
    }

    private func row(for host: Host) -> some View {
        let unavailable = app.hosts.keyExportUnavailableReason(for: host)
        return Button {
            chooser.activate(host.id)
        } label: {
            HStack(spacing: Metrics.Space.m) {
                SelectionMark(
                    mode: .multiple, isSelected: chooser.selected.contains(host.id)
                )

                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text(host.name)
                        .foregroundStyle(unavailable == nil ? .primary : .secondary)
                        .lineLimit(1)
                    Text(app.hosts.loginAddress(for: host))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: Metrics.Space.s)
                stateLabel(for: host, unavailable: unavailable)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil || isExporting || isFinished)
        .accessibilityAddTraits(chooser.selected.contains(host.id) ? .isSelected : [])
    }

    @ViewBuilder
    private func stateLabel(for host: Host, unavailable: String?) -> some View {
        switch states[host.id] {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Label("Exported", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .help(Text(message))
        case nil:
            if let unavailable {
                Text(unavailable)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack {
            if isFinished {
                let failures = states.values.reduce(into: 0) { count, state in
                    if case .failed = state { count += 1 }
                }
                Text(
                    failures == 0
                        ? successSummary(hostCount: states.count)
                        : String(localized: "\(states.count - failures) exported, \(failures) failed")
                )
                .font(.caption)
                .foregroundStyle(
                    failures == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                )
                .monospacedDigit()
            } else {
                Text("\(chooser.selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button(allEligibleChecked ? "Deselect All" : "Select All") {
                    toggleAllEligible()
                }
                .disabled(eligibleHosts.isEmpty || isExporting)
            }

            Spacer()

            Button(isFinished ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isExporting)

            if !isFinished {
                Button("Export", action: export)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chooser.selected.isEmpty || isExporting)
            }
        }
        .padding(Metrics.Space.l)
    }

    private var allEligibleChecked: Bool {
        !eligibleHosts.isEmpty && eligibleHosts.allSatisfy {
            chooser.selected.contains($0.id)
        }
    }

    private var keySummary: String {
        if keys.count == 1 {
            return keys[0].label
        }
        return String(localized: "\(keys.count) keys")
    }

    private func successSummary(hostCount: Int) -> String {
        if keys.count == 1 {
            return hostCount == 1
                ? String(localized: "Exported to 1 host")
                : String(localized: "Exported to \(hostCount) hosts")
        }
        return hostCount == 1
            ? String(localized: "Exported \(keys.count) keys to 1 host")
            : String(localized: "Exported \(keys.count) keys to \(hostCount) hosts")
    }

    /// Select All follows the visible, filtered list, matching the host chooser:
    /// a filter must never cause an invisible machine to be modified.
    private func toggleAllEligible() {
        let ids = eligibleHosts.map(\.id)
        chooser.toggleAll(visible: ids, enabled: Set(ids))
    }

    private func moveCursor(_ delta: Int) -> KeyPress.Result {
        let ids = eligibleHosts.map(\.id)
        chooser.moveCursor(by: delta, through: ids)
        return ids.isEmpty ? .ignored : .handled
    }

    private func toggleCursor() -> KeyPress.Result {
        guard let cursor = chooser.cursor else { return .ignored }
        chooser.toggle(cursor)
        return .handled
    }

    private func export() {
        let targets = app.hosts.searchHosts("").filter {
            chooser.selected.contains($0.id)
        }
        guard !targets.isEmpty else { return }

        var configurations: [(Host.ID, SSHConnectionConfiguration)] = []
        for host in targets {
            if let reason = app.hosts.keyExportUnavailableReason(for: host) {
                states[host.id] = .failed(reason)
                continue
            }
            do {
                configurations.append(
                    (host.id, try app.hosts.sshConnectionConfiguration(for: host))
                )
                states[host.id] = .running
            } catch {
                states[host.id] = .failed(error.localizedDescription)
            }
        }

        let publicKeys = keys.map(\.publicKey)
        let connectionCoordinator = app.connections
        Task {
            await withTaskGroup(of: (Host.ID, String?).self) { group in
                for (id, configuration) in configurations {
                    group.addTask {
                        do {
                            for publicKey in publicKeys {
                                try await connectionCoordinator.installAuthorizedKey(
                                    publicKey, using: configuration
                                )
                            }
                            return (id, nil)
                        } catch {
                            return (id, error.localizedDescription)
                        }
                    }
                }
                for await (id, error) in group {
                    states[id] = error.map(ExportState.failed) ?? .succeeded
                }
            }
        }
    }
}

// MARK: - Key card

/// The singular actions for one key, shared by its card and ContextPanel detail.
/// Secret material is intentionally absent: only the public key and fingerprint
/// ever enter this view layer.
struct KeyObjectActions: View {
    let key: SSHKeyRef
    let rename: () -> Void
    let export: () -> Void

    var body: some View {
        Button("Copy Fingerprint") { copyToPasteboard(key.fingerprint) }
        Button("Copy Public Key") { copyToPasteboard(key.publicKey) }
            .disabled(key.publicKey.isEmpty)
        Divider()
        Button("Export to Hosts", action: export)
            .disabled(key.publicKey.isEmpty)
        Divider()
        Button("Rename", action: rename)
    }
}

private struct KeyCard: View {
    let key: SSHKeyRef
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionKeys: [SSHKeyRef]
    let actionIdentities: [Identity]
    let rename: () -> Void
    let export: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    /// Deleting a key breaks every identity pointing at it, so the card says how
    /// many that is before anyone finds out the hard way.
    private var dependents: Int {
        app.hosts.identities(using: key.id).count
    }

    var body: some View {
        CardTile(
            selectionID: ContextPanelDetailID.key(key.id),
            isSelected: isSelected,
            select: select,
            extendSelection: extendSelection
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.m) {
                    CardIcon(symbol: "key.fill", tint: .orange)

                    // The fingerprint is deliberately *not* selectable, and this
                    // is not a style preference.
                    //
                    // A SHA256 fingerprint is wider than the widest card, so it
                    // has to truncate. `.textSelection(.enabled)` used to be on
                    // the line below, and it laid out correctly right up until
                    // someone clicked it: entering selection mode re-lays the
                    // text out at its full width, and it walked out of the card
                    // and over its neighbour. That made it look like a rendering
                    // glitch rather than a layout bug, because no static
                    // screenshot ever showed it.
                    //
                    // Nothing is lost. The whole fingerprint is on the tooltip
                    // below and one right-click away via Copy Fingerprint, which
                    // is a better trade than a card that changes size when you
                    // touch it. The old forwarding manager had the same defect for the
                    // same reason.
                    //
                    // The frame keeps the column to the width it is offered, so
                    // no future subtitle can push the card wide either.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.label)
                            .font(.headline)
                            .lineLimit(1)
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: Metrics.Space.xs) {
                    CardChip(text: keyDisplayName)
                    if key.hasPassphrase {
                        CardChip(
                            text: key.storesPassphrase
                                ? String(localized: "Passphrase Saved")
                                : String(localized: "Passphrase Required"),
                            symbol: "lock.fill"
                        )
                    }
                    CardChip(
                        text: key.storage.displayName,
                        symbol: key.storage.symbol
                    )

                    Spacer(minLength: Metrics.Space.xs)

                    if dependents > 0 {
                        Text("\(dependents) identities")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .contextMenu {
            if actionKeys.count == 1, actionIdentities.isEmpty {
                KeyObjectActions(key: key, rename: rename, export: export)
            } else if actionIdentities.isEmpty {
                Button("Export to Hosts", action: export)
                    .disabled(actionKeys.isEmpty || actionKeys.contains { $0.publicKey.isEmpty })
                Divider()
            }
            Button("Delete", role: .destructive, action: delete)
        }
        .help(Text(key.fingerprint))
    }

    private var keyDisplayName: String {
        if key.algorithm == .rsa, let bits = key.keySize {
            return "RSA \(bits)"
        }
        return key.algorithm.displayName
    }
}

// MARK: - Identity card

struct IdentityObjectActions: View {
    let edit: () -> Void

    var body: some View {
        Button("Edit", action: edit)
    }
}

private struct IdentityCard: View {
    let identity: Identity
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionKeys: [SSHKeyRef]
    let actionIdentities: [Identity]
    let edit: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    /// The key this identity signs with, resolved through the store so renaming a
    /// key renames it here too.
    private var key: SSHKeyRef? {
        identity.keyID.flatMap { app.hosts.key($0) }
    }

    var body: some View {
        CardTile(
            selectionID: ContextPanelDetailID.identity(identity.id),
            isSelected: isSelected,
            select: select,
            extendSelection: extendSelection
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.m) {
                    CardIcon(symbol: "person.badge.key.fill", tint: .accentColor)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(identity.username)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: Metrics.Space.xs)
                }

                HStack(spacing: Metrics.Space.xs) {
                    secretChip

                    Spacer(minLength: Metrics.Space.xs)

                    Text(
                        identity.lastUsedAt
                            .map { $0.formatted(.relative(presentation: .numeric)) }
                            ?? String(localized: "Never")
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
        }
        .contextMenu {
            if actionKeys.isEmpty, actionIdentities.count == 1 {
                IdentityObjectActions(edit: edit)
            }
            Button("Delete", role: .destructive, action: delete)
        }
        .help(Text(identity.notes.isEmpty ? identity.username : identity.notes))
    }

    /// One chip per secret the identity actually has — so a login with both
    /// shows both, rather than the card picking a winner and hiding the other.
    ///
    /// A dangling key reference gets its own chip rather than disappearing: an
    /// identity that quietly stopped signing with a key is exactly the thing you
    /// want to find out about here and not at connect time. Neither secret is a
    /// legal state too, and it says so — an unfinished identity should look
    /// unfinished.
    @ViewBuilder
    private var secretChip: some View {
        if identity.usesPassword {
            CardChip(text: String(localized: "Password"), symbol: "lock.fill")
        }

        if identity.usesKey {
            if let key {
                CardChip(text: key.label, symbol: "key.fill", tint: .orange)
            } else {
                CardChip(
                    text: String(localized: "Key missing"),
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }

        if !identity.hasSecret {
            CardChip(text: String(localized: "No secret"), symbol: "questionmark.circle")
        }
    }
}
