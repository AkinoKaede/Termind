import AppKit
import ListViewKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class KeychainPageState {
    var query = ""
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
/// Private material is loaded only by the explicit Import/Edit work surfaces;
/// cards and selection details continue to operate on public metadata.
struct KeychainPageView: ManagedCardPage {
    nonisolated enum SectionID: Hashable {
        case keys
        case identities
    }

    nonisolated enum Item: Identifiable, Hashable, Sendable {
        case key(SSHKeyRef)
        case identity(Identity)

        var id: VaultSelectionID {
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

    let state: KeychainPageState

    init(state: KeychainPageState = KeychainPageState()) {
        self.state = state
    }

    private var keys: [SSHKeyRef] { app.credentials.searchKeys(state.query) }
    private var identities: [Identity] { app.credentials.searchIdentities(state.query) }

    private var selection: Set<VaultSelectionID> {
        Set(window.vaultSelection(for: .keychain))
    }

    private var isEmpty: Bool {
        app.credentials.keys.isEmpty && app.credentials.identities.isEmpty
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

    var managedSelection: ManagedCardSelection<VaultSelectionID> {
        ManagedCardSelection(selected: { selection }, update: setSelection)
    }

    var managedCapabilities: ManagedCardCapabilities<SectionID, VaultSelectionID> {
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
                    app.credentials.move(keyIDs: keyIDs, before: next?.keyID)
                case .identities:
                    let identityIDs = ids.compactMap(\.identityID)
                    app.credentials.move(identityIDs: identityIDs, before: next?.identityID)
                }
            }
        )
    }

    var isManagedSourceEmpty: Bool { isEmpty }

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
                edit: {
                    window.openVaultWork(.editKey(key.id), on: .keychain)
                },
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
                edit: {
                    window.openVaultWork(.identityEditor(identity.id), on: .keychain)
                },
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
                actionKeys: [], actionIdentities: [], edit: {}, export: {}, delete: {}
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

    /// Both sections offer every verb: a key and an identity are made in the
    /// same visit often enough that hiding one behind the other section would
    /// just be a second right-click.
    func managedBlankAreaMenu(for section: SectionID?) -> [NativeMenuEntry] {
        [
            NativeMenuEntry(title: String(localized: "Import Key")) {
                window.openVaultWork(.importKey, on: .keychain)
            },
            NativeMenuEntry(title: String(localized: "Generate Key")) {
                window.openVaultWork(.generateKey, on: .keychain)
            },
            .separator,
            NativeMenuEntry(title: String(localized: "New Identity")) {
                window.openVaultWork(.identityEditor(nil), on: .keychain)
            },
        ]
    }

    // MARK: - Selection

    private func setSelection(_ selected: Set<VaultSelectionID>) {
        let ordered: [VaultSelectionID] =
            keys.compactMap { selected.contains(.key($0.id)) ? .key($0.id) : nil }
            + identities.compactMap {
                selected.contains(.identity($0.id)) ? .identity($0.id) : nil
            }
        window.setVaultSelection(ordered, for: .keychain)
    }

    private func requestExport(_ keys: [SSHKeyRef]) {
        guard !keys.isEmpty else { return }
        window.openVaultWork(.exportKeys(keys.map(\.id)), on: .keychain)
    }

    /// Identities go first so deleting a mixed selection never leaves a host
    /// pointing at an identity whose key was removed moments earlier. Keychain
    /// failures leave that key selected and report the first error.
    private func delete(keys: [SSHKeyRef], identities: [Identity]) {
        for identity in identities {
            if !app.credentials.delete(identityID: identity.id) {
                state.errorMessage = app.credentials.storageError
                    ?? String(localized: "The identity could not be deleted.")
            }
        }
        for key in keys {
            do {
                try app.credentials.delete(keyID: key.id)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
        window.pruneVaultSelections(in: app.credentials)
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
            Button("New Identity") {
                window.openVaultWork(.identityEditor(nil), on: .keychain)
            }
            Button("Import Key") {
                window.openVaultWork(.importKey, on: .keychain)
            }
            Button("Generate Key") {
                window.openVaultWork(.generateKey, on: .keychain)
            }
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
                pruneSelection: { window.pruneVaultSelections(in: app.credentials) }
            )
        )
    }

}

struct KeychainPagePresentation: ManagedCardPresentationModifier {
    struct Actions {
        let pruneSelection: () -> Void
    }

    let state: KeychainPageState
    let actions: Actions

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
            .onAppear(perform: actions.pruneSelection)
            // A refused Keychain delete used to be a line of orange text in the
            // page toolbar. With the toolbar gone it needs somewhere it cannot
            // be missed: leaving a key the user asked to remove sitting there
            // with no explanation is the one outcome worth interrupting for.
            .alert(
                "Keychain Operation Failed",
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button("OK") { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
    }
}

struct KeychainImportDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        SoftwareKeyEditor(
            title: "Import Key", symbol: "square.and.arrow.down",
            close: window.closeVaultWork, save: save
        )
    }

    private func save(
        name: String, colorTag: TagColor, storage: KeyStorage, privateKey: String,
        passphrase: String?, certificate: String, material: SSHKeyMaterial
    ) async throws -> SSHKeyRef {
        let key = SSHKeyRef(
            label: name.isEmpty ? material.algorithm.typeName : name,
            algorithm: material.algorithm, publicKey: material.publicKey,
            certificate: certificate, fingerprint: material.fingerprint,
            credentialRef: "termind.key.\(UUID().uuidString)", storage: storage,
            keySize: material.keySize, hasPassphrase: passphrase != nil,
            createdAt: Date(), colorTag: colorTag
        )
        try app.credentials.upsert(
            key,
            credential: .software(
                SSHPrivateKeySecret(privateKey: privateKey)
            )
        )
        window.selectVaultItem(.key(key.id), on: .keychain)
        return key
    }
}

private struct SoftwareKeyEditor: View {
    let existing: SSHKeyRef?
    let title: String
    let symbol: String
    let close: () -> Void
    let loadPrivateKey: (() throws -> String)?
    let save:
        (
            _ name: String, _ colorTag: TagColor, _ storage: KeyStorage, _ privateKey: String,
            _ passphrase: String?, _ certificate: String, _ material: SSHKeyMaterial
        ) async throws -> SSHKeyRef

    @State private var name: String
    @State private var colorTag: TagColor
    @State private var storage: KeyStorage
    @State private var privateKey = ""
    @State private var originalPrivateKey = ""
    @State private var passphrase = ""
    @State private var certificate: String
    @State private var material: SSHKeyMaterial?
    @State private var isLoading: Bool
    @State private var isChoosingFile = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        existing: SSHKeyRef? = nil, title: String,
        symbol: String, close: @escaping () -> Void,
        loadPrivateKey: (() throws -> String)? = nil,
        save: @escaping (
            String, TagColor, KeyStorage, String, String?, String, SSHKeyMaterial
        ) async throws -> SSHKeyRef
    ) {
        self.existing = existing
        self.title = title
        self.symbol = symbol
        self.close = close
        self.loadPrivateKey = loadPrivateKey
        self.save = save
        _name = State(initialValue: existing?.label ?? "")
        _colorTag = State(initialValue: existing?.colorTag ?? .none)
        _storage = State(initialValue: existing?.storage ?? .iCloud)
        _certificate = State(initialValue: existing?.certificate ?? "")
        _isLoading = State(initialValue: loadPrivateKey != nil)
    }

    var body: some View {
        VaultDetailScaffold(title: title, symbol: symbol, close: close) {
            if isLoading {
                ProgressView("Loading private key…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Key") {
                        TextField("Name", text: $name, prompt: Text("Defaults to key type"))
                        LabeledContent("Color") {
                            ColorTagPicker(selection: $colorTag)
                        }
                        Picker("Store in", selection: $storage) {
                            Label("iCloud", systemImage: "icloud.fill").tag(KeyStorage.iCloud)
                            Label("This Mac", systemImage: "lock.laptopcomputer").tag(KeyStorage.thisDevice)
                        }
                    }

                    Section("Private Key") {
                        HStack {
                            Text("Private Key")
                            Spacer()
                            Button("Choose File…") { isChoosingFile = true }
                                .controlSize(.small)
                        }
                        TextEditor(text: $privateKey)
                            .font(.caption.monospaced())
                            .frame(minHeight: 150)
                            .accessibilityLabel("Private Key")
                        SecureField("Passphrase", text: $passphrase, prompt: Text("Optional"))
                    }

                    Section("Public Key") {
                        Text(publicKeyDisplay)
                            .font(.caption.monospaced())
                            .foregroundStyle(material == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                    }

                    Section("Certificate") {
                        TextEditor(text: $certificate)
                            .font(.caption.monospaced())
                            .frame(minHeight: 110)
                            .overlay(alignment: .topLeading) {
                                if certificate.isEmpty {
                                    Text("Certificate (optional)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8).padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                        if let warning = certificateWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let existing, let material,
                            material.publicKey != existing.publicKey
                        {
                            Label(
                                "Replacing this private key changes its public key. Hosts using the old key may reject the next connection.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } footer: {
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Import" : "Save") {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || isLoading || privateKey.isEmpty)
            }
            .padding()
        }
        .fileImporter(
            isPresented: $isChoosingFile, allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: true, onCompletion: receiveFiles
        )
        .dropDestination(for: URL.self) { urls, _ in
            receive(urls: urls)
        }
        .task { load() }
        .task(id: validationToken) { await derivePublicMaterial() }
    }

    @MainActor
    private func commit() async {
        isWorking = true
        errorMessage = nil
        do {
            let passphrase = passphrase.isEmpty ? nil : passphrase
            let inspected: SSHKeyMaterial
            if let existing, privateKey == originalPrivateKey {
                inspected = SSHKeyMaterial(
                    privateKey: privateKey, publicKey: existing.publicKey,
                    algorithm: existing.algorithm, fingerprint: existing.fingerprint,
                    keySize: existing.keySize
                )
            } else {
                let keyText = privateKey
                let comment = name
                inspected = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyMaterial.inspect(
                        privateKey: keyText, passphrase: passphrase, comment: comment
                    )
                }.value
            }
            let normalizedCertificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedCertificate.isEmpty {
                _ = try SSHUserCertificate.parse(
                    normalizedCertificate, matching: inspected.publicKey
                )
            }
            _ = try await save(
                name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, storage,
                privateKey, passphrase, normalizedCertificate, inspected
            )
            close()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    private var validationToken: String { privateKey + "\u{0}" + passphrase }

    private var publicKeyDisplay: String {
        material?.publicKey ?? existing?.publicKey ?? String(localized: "Derived from the private key")
    }

    private var certificateWarning: String? {
        guard !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try SSHUserCertificate.parse(
                certificate, matching: material?.publicKey ?? existing?.publicKey
            ).validityWarning
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    private func load() {
        guard isLoading else { return }
        do {
            privateKey = try loadPrivateKey?() ?? ""
            originalPrivateKey = privateKey
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func derivePublicMaterial() async {
        guard !privateKey.isEmpty else {
            material = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let privateKey = privateKey
            let passphrase = passphrase.isEmpty ? nil : passphrase
            let comment = name
            material = try await Task.detached(priority: .utility) {
                try SSHKeyMaterial.inspect(
                    privateKey: privateKey, passphrase: passphrase, comment: comment
                )
            }.value
        } catch is CancellationError {
        } catch {
            material = nil
        }
    }

    private func receiveFiles(_ result: Result<[URL], any Error>) {
        do {
            _ = receive(urls: try result.get())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func receive(urls: [URL]) -> Bool {
        do {
            guard !urls.isEmpty else { return false }
            var found = false
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("PRIVATE KEY") {
                    privateKey = text
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    found = true
                } else if text.contains("-cert-v01@openssh.com") {
                    certificate = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    found = true
                } else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "Choose a private key or OpenSSH user certificate file.")]
                    )
                }
            }
            errorMessage = nil
            return found
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct KeychainGenerateDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        GenerateKeySheet(generate: generate, close: window.closeVaultWork)
    }

    private func generate(
        label: String, colorTag: TagColor, generation: SSHKeyMaterial.Generation, passphrase: String?,
        cipher: SSHKeyMaterial.Cipher, rounds: Int, storage: KeyStorage,
        requiresUserPresence: Bool
    ) async throws -> SSHKeyRef {
        let comment = "termind@\(ProcessInfo.processInfo.hostName)"
        let key: SSHKeyRef
        if storage == .secureEnclave {
            let material = try await Task.detached(priority: .userInitiated) {
                try SecureEnclaveKey.generate(
                    comment: comment, requiresUserPresence: requiresUserPresence
                )
            }.value
            key = SSHKeyRef(
                label: label, algorithm: .ecdsa256, publicKey: material.publicKey,
                fingerprint: material.fingerprint,
                credentialRef: "termind.key.\(UUID().uuidString)",
                storage: .secureEnclave, keySize: 256, hasPassphrase: false,
                requiresUserPresence: requiresUserPresence,
                createdAt: Date(), colorTag: colorTag
            )
            try app.credentials.upsert(key, credential: .secureEnclave(material.credential))
        } else {
            let material = try await Task.detached(priority: .userInitiated) {
                try SSHKeyMaterial.generate(
                    generation, comment: comment, passphrase: passphrase,
                    cipher: cipher, rounds: rounds
                )
            }.value
            key = SSHKeyRef(
                label: label, algorithm: material.algorithm,
                publicKey: material.publicKey, fingerprint: material.fingerprint,
                credentialRef: "termind.key.\(UUID().uuidString)", storage: storage,
                keySize: material.keySize, hasPassphrase: passphrase != nil,
                createdAt: Date(), colorTag: colorTag
            )
            try app.credentials.upsert(
                key,
                credential: .software(
                    SSHPrivateKeySecret(privateKey: material.privateKey)
                )
            )
        }
        window.selectVaultItem(.key(key.id), on: .keychain)
        return key
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
            String, TagColor, SSHKeyMaterial.Generation, String?, SSHKeyMaterial.Cipher, Int,
            KeyStorage, Bool
        ) async throws -> SSHKeyRef
    let close: () -> Void

    @State private var label = ""
    @State private var colorTag = TagColor.none
    @State private var storage = KeyStorage.iCloud
    @State private var kind = Kind.ed25519
    @State private var curveBits = 256
    @State private var rsaBits = 3072
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var cipher = SSHKeyMaterial.Cipher.aes256
    @State private var rounds = 100
    @State private var requiresUserPresence = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let availableStorage: [KeyStorage] = [
        .thisDevice,
        .iCloud,
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
        VaultDetailScaffold(title: "Generate Key", symbol: "key.fill", close: close) {
            Form {
                TextField("Name", text: $label, prompt: Text(defaultName))
                LabeledContent("Color") {
                    ColorTagPicker(selection: $colorTag)
                }
                Picker("Store in", selection: $storage) {
                    ForEach(availableStorage) { location in
                        Label(location.displayName, systemImage: location.symbol)
                            .tag(location)
                            .disabled(location == .secureEnclave && !SecureEnclaveKey.isAvailable)
                    }
                }
                if storage == .secureEnclave {
                    LabeledContent("Algorithm", value: "ECDSA")
                    LabeledContent("Elliptic Curve", value: "NIST P-256")
                    Toggle("Require Authentication", isOn: $requiresUserPresence)
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
                        Picker("Elliptic Curve", selection: $curveBits) {
                            Text("NIST P-256").tag(256)
                            Text("NIST P-384").tag(384)
                            Text("NIST P-521").tag(521)
                        }
                    } else if kind == .rsa {
                        Picker("Key Size", selection: $rsaBits) {
                            Text("2048 bit").tag(2048)
                            Text("3072 bit").tag(3072)
                            Text("4096 bit").tag(4096)
                        }
                    }
                    SecureField("Passphrase", text: $passphrase, prompt: Text("Optional"))
                    SecureField("Confirm Passphrase", text: $confirmation)
                        .disabled(passphrase.isEmpty)
                    if !passphrase.isEmpty {
                        Picker("Cipher", selection: $cipher) {
                            ForEach(SSHKeyMaterial.Cipher.allCases) { cipher in
                                Text(cipher.displayName).tag(cipher)
                            }
                        }
                        TextField("Rounds", value: $rounds, format: .number)
                    }
                    if !passwordsMatch {
                        Text("Passphrases do not match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(
                        passphrase.isEmpty
                            ? "The generated private key is stored in the selected Keychain."
                            : "The private key is encrypted. Termind never saves its passphrase and asks for it when needed."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Generate") {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isWorking || (storage != .secureEnclave && (!passwordsMatch || (!passphrase.isEmpty && rounds <= 0)))
                        || (storage == .secureEnclave && !SecureEnclaveKey.isAvailable)
                )
            }
            .padding()
        }
    }

    @MainActor
    private func commit() async {
        isWorking = true
        errorMessage = nil
        do {
            _ = try await generate(
                resolvedLabel, colorTag, generation,
                storage == .secureEnclave || passphrase.isEmpty ? nil : passphrase,
                cipher, rounds, storage,
                storage == .secureEnclave && requiresUserPresence
            )
            close()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    private var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private var defaultName: String {
        storage == .secureEnclave ? "Secure Enclave" : kind.rawValue
    }
}

struct KeychainEditDetail: View {
    let keyID: SSHKeyRef.ID

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @ViewBuilder
    var body: some View {
        if let key = app.credentials.key(keyID) {
            if key.storage == .secureEnclave {
                SecureEnclaveKeyEditor(
                    key: key, close: window.closeVaultWork,
                    save: { name, colorTag in
                        try saveSecureEnclave(key, name: name, colorTag: colorTag)
                    }
                )
            } else {
                SoftwareKeyEditor(
                    existing: key, title: "Edit Key", symbol: "pencil",
                    close: window.closeVaultWork,
                    loadPrivateKey: { try loadPrivateKey(key) },
                    save: {
                        name, colorTag, storage, privateKey, passphrase, certificate, material in
                        try await saveSoftwareKey(
                            key, name: name, colorTag: colorTag, storage: storage,
                            privateKey: privateKey, passphrase: passphrase,
                            certificate: certificate, material: material
                        )
                    }
                )
            }
        } else {
            ContentUnavailableView("Key Unavailable", systemImage: "key.slash")
        }
    }

    private func loadPrivateKey(_ key: SSHKeyRef) throws -> String {
        guard case .software(let secret)? = try app.credentials.keyCredential(for: key) else {
            throw TermindSSHError.library(
                String(localized: "The private key is unavailable on this Mac.")
            )
        }
        return secret.privateKey
    }

    private func saveSoftwareKey(
        _ original: SSHKeyRef, name: String, colorTag: TagColor, storage: KeyStorage,
        privateKey: String, passphrase: String?, certificate: String,
        material: SSHKeyMaterial
    ) async throws -> SSHKeyRef {
        var updated = original
        updated.label = name.isEmpty ? material.algorithm.typeName : name
        updated.colorTag = colorTag
        updated.storage = storage
        updated.algorithm = material.algorithm
        updated.publicKey = material.publicKey
        updated.certificate = certificate
        updated.fingerprint = material.fingerprint
        updated.keySize = material.keySize
        let keepsOriginalPrivateKey = privateKey == (try loadPrivateKey(original))
        updated.hasPassphrase = passphrase != nil || (keepsOriginalPrivateKey && original.hasPassphrase)
        try app.credentials.upsert(
            updated,
            credential: .software(
                SSHPrivateKeySecret(privateKey: privateKey)
            )
        )
        window.selectVaultItem(.key(updated.id), on: .keychain)
        return updated
    }

    private func saveSecureEnclave(
        _ original: SSHKeyRef, name: String, colorTag: TagColor
    ) throws {
        var updated = original
        updated.label = name
        updated.colorTag = colorTag
        try app.credentials.upsert(updated)
        window.selectVaultItem(.key(updated.id), on: .keychain)
    }
}

private struct SecureEnclaveKeyEditor: View {
    let key: SSHKeyRef
    let close: () -> Void
    let save: (String, TagColor) throws -> Void

    @State private var name: String
    @State private var colorTag: TagColor
    @State private var errorMessage: String?

    init(
        key: SSHKeyRef, close: @escaping () -> Void,
        save: @escaping (String, TagColor) throws -> Void
    ) {
        self.key = key
        self.close = close
        self.save = save
        _name = State(initialValue: key.label)
        _colorTag = State(initialValue: key.colorTag)
    }

    var body: some View {
        VaultDetailScaffold(title: "Edit Key", symbol: "pencil", close: close) {
            Form {
                Section("Key") {
                    TextField("Name", text: $name)
                    LabeledContent("Color") {
                        ColorTagPicker(selection: $colorTag)
                    }
                }
                Section("Secure Enclave") {
                    LabeledContent("Stored in", value: key.storage.displayName)
                    LabeledContent("Algorithm", value: key.algorithm.displayName)
                    LabeledContent("Fingerprint") {
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Public Key") {
                        Text(key.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("The private key cannot leave the Secure Enclave. Only its name can be changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill") }
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save(
                            name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag
                        )
                        close()
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
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
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss

    @State private var chooser = ManagedChooserState<Host.ID>(mode: .multiple)
    @State private var states: [Host.ID: ExportState] = [:]
    @FocusState private var searchFocused: Bool

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        Binding(get: { chooser.query }, set: { chooser.query = $0 })
    }
    private var hosts: [Host] { app.credentials.searchHosts(query) }
    private var eligibleHosts: [Host] {
        hosts.filter { app.credentials.keyExportUnavailableReason(for: $0) == nil }
    }
    private var isExporting: Bool { states.values.contains(.running) }
    private var isFinished: Bool { !states.isEmpty && !isExporting }

    var body: some View {
        VaultDetailScaffold(title: "Export to Hosts", symbol: "square.and.arrow.up", close: close) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.7)
                content
            }
        } footer: {
            footer
        }
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
                CardIcon(symbol: "key.fill", tint: TermindColor.accent)
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
        if app.credentials.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add and connect to a host before exporting a key to it.")
            }
        } else if hosts.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ExportHostNativeList(items: exportHostItems) { item in
                row(for: item.host)
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
        }
    }

    private var exportHostItems: [ExportHostListItem] {
        hosts.map { host in
            let stateKey: String
            switch states[host.id] {
            case .running: stateKey = "running"
            case .succeeded: stateKey = "succeeded"
            case .failed(let message): stateKey = "failed:\(message)"
            case nil: stateKey = "idle"
            }
            return ExportHostListItem(
                host: host,
                isCursor: chooser.cursor == host.id,
                isSelected: chooser.selected.contains(host.id),
                unavailable: app.credentials.keyExportUnavailableReason(for: host),
                stateKey: stateKey,
                isDisabled: isExporting || isFinished
            )
        }
    }

    private func row(for host: Host) -> some View {
        let unavailable = app.credentials.keyExportUnavailableReason(for: host)
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
                    Text(app.credentials.loginAddress(for: host))
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

            Button(isFinished ? "Done" : "Cancel", action: close)
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

    private func close() {
        if window.selectedDestination == .vault {
            window.closeVaultWork()
        } else {
            dismiss()
        }
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
        let targets = app.credentials.searchHosts("").filter {
            chooser.selected.contains($0.id)
        }
        guard !targets.isEmpty else { return }

        var configurations: [(Host.ID, SSHConnectionConfiguration)] = []
        for host in targets {
            if let reason = app.credentials.keyExportUnavailableReason(for: host) {
                states[host.id] = .failed(reason)
                continue
            }
            do {
                configurations.append(
                    (host.id, try app.credentials.sshConnectionConfiguration(for: host))
                )
                states[host.id] = .running
            } catch {
                states[host.id] = .failed(error.localizedDescription)
            }
        }

        let exportKeys = keys.map { (name: $0.label, publicKey: $0.publicKey) }
        let connectionCoordinator = app.connections
        Task {
            await withTaskGroup(of: (Host.ID, String?).self) { group in
                for (id, configuration) in configurations {
                    group.addTask {
                        do {
                            for key in exportKeys {
                                try await connectionCoordinator.installAuthorizedKey(
                                    key.publicKey, named: key.name, using: configuration
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

nonisolated private struct ExportHostListItem: CursorHostingListItem, Sendable {
    let host: Host
    let isCursor: Bool
    let isSelected: Bool
    let unavailable: String?
    let stateKey: String
    let isDisabled: Bool
    var id: Host.ID { host.id }
}

private typealias ExportHostNativeList = CursorHostingList<ExportHostListItem>

// MARK: - Key card

/// The singular actions for one key, shared by its card and editor surfaces.
/// Card actions never resolve secret material; Edit is the explicit boundary
/// that loads a software key from Keychain.
struct KeyObjectActions: View {
    let key: SSHKeyRef
    let edit: () -> Void
    let export: () -> Void

    var body: some View {
        Button("Copy Fingerprint") { copyToPasteboard(key.fingerprint) }
        Button("Copy Public Key") { copyToPasteboard(key.publicKey) }
            .disabled(key.publicKey.isEmpty)
        Divider()
        Button("Export to Hosts", action: export)
            .disabled(key.publicKey.isEmpty)
        Divider()
        Button("Edit", action: edit)
    }
}

private struct KeyCard: View {
    let key: SSHKeyRef
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionKeys: [SSHKeyRef]
    let actionIdentities: [Identity]
    let edit: () -> Void
    let export: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    /// Deleting a key breaks every identity pointing at it, so the card says how
    /// many that is before anyone finds out the hard way.
    private var dependents: Int {
        app.credentials.identities(using: key.id).count
    }

    var body: some View {
        CardTile(
            selectionID: VaultSelectionID.key(key.id),
            isSelected: isSelected,
            select: select,
            extendSelection: extendSelection
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.m) {
                    CardIcon(
                        symbol: "key.fill",
                        tint: key.colorTag.color ?? TermindColor.accent
                    )

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
                            text: String(localized: "Passphrase Required"),
                            symbol: "lock.fill"
                        )
                    }
                    CardChip(
                        text: key.storage.displayName,
                        symbol: key.storage.symbol
                    )
                    switch app.credentials.keyAvailability(for: key) {
                    case .missing:
                        CardChip(
                            text: String(localized: "Private key missing"),
                            symbol: "exclamationmark.triangle.fill", tint: .orange
                        )
                    case .failed:
                        CardChip(
                            text: String(localized: "Keychain unavailable"),
                            symbol: "exclamationmark.triangle.fill", tint: .orange
                        )
                    case .available, .notConfigured:
                        EmptyView()
                    }

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
                KeyObjectActions(key: key, edit: edit, export: export)
            } else if actionIdentities.isEmpty {
                Button("Export to Hosts", action: export)
                    .disabled(actionKeys.isEmpty || actionKeys.contains { $0.publicKey.isEmpty })
                Divider()
            }
            DestructiveMenuButton("Delete", action: delete)
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
        identity.keyID.flatMap { app.credentials.key($0) }
    }

    var body: some View {
        CardTile(
            selectionID: VaultSelectionID.identity(identity.id),
            isSelected: isSelected,
            select: select,
            extendSelection: extendSelection
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.m) {
                    CardIcon(
                        symbol: "person.badge.key.fill",
                        tint: identity.colorTag.color ?? .accentColor
                    )

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
            DestructiveMenuButton("Delete", action: delete)
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
            switch app.credentials.passwordAvailability(for: identity) {
            case .available:
                CardChip(text: String(localized: "Password"), symbol: "lock.fill")
            case .missing:
                CardChip(
                    text: String(localized: "Password missing"),
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
            case .failed:
                CardChip(
                    text: String(localized: "Password unavailable"),
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
            case .notConfigured:
                EmptyView()
            }
        }

        if identity.usesKey {
            if let key {
                CardChip(
                    text: key.label, symbol: "key.fill",
                    tint: key.colorTag.color ?? TermindColor.accent
                )
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
