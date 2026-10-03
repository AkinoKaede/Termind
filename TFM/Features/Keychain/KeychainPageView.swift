import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import UniformTypeIdentifiers

import struct TermindDomain.Host

@Observable
final class KeychainPageState {
    var query = ""
    var errorMessage: String?
    var deleting: [KeychainPageView.Item] = []

    func requestDeletion(of items: [KeychainPageView.Item]) {
        guard !items.isEmpty,
            DeletionContentCategory.protectedData.requiresConfirmation(for: .item)
        else { return }
        deleting = items
    }
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
    @Environment(VaultWorkEditingSession.self) private var editingSession

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
                id: .keys, title: String(localized: AppStrings.Keychain.keys),
                items: keys.map(Item.key), showsWhenEmpty: state.query.isEmpty
            ),
            ManagedCardSection(
                id: .identities, title: String(localized: AppStrings.Keychain.identities),
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
                select: { select(item, action: context.select) },
                extendSelection: context.extendSelection,
                actionKeys: context.actionItems.compactMap(\.key),
                actionIdentities: context.actionItems.compactMap(\.identity),
                edit: {
                    edit(item, action: context.select)
                },
                export: { requestExport(context.actionItems.compactMap(\.key)) },
                delete: {
                    requestDelete(context.actionItems)
                }
            )
        case .identity(let identity):
            IdentityCard(
                identity: identity,
                isSelected: context.isSelected,
                select: { select(item, action: context.select) },
                extendSelection: context.extendSelection,
                actionKeys: context.actionItems.compactMap(\.key),
                actionIdentities: context.actionItems.compactMap(\.identity),
                edit: {
                    edit(item, action: context.select)
                },
                delete: {
                    requestDelete(context.actionItems)
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
            NativeMenuEntry(
                title: AppStrings.Keychain.importKey, symbol: MenuSymbol.importItem
            ) {
                window.openVaultWork(.importKey, on: .keychain)
            },
            NativeMenuEntry(
                title: AppStrings.Keychain.generateKey, symbol: MenuSymbol.generateKey
            ) {
                window.openVaultWork(.generateKey, on: .keychain)
            },
            .separator,
            NativeMenuEntry(
                title: AppStrings.Keychain.newIdentity, symbol: MenuSymbol.newIdentity
            ) {
                window.openVaultWork(.identityEditor(nil), on: .keychain)
            },
            .separator,
            NativeMenuEntry(title: AppStrings.Vault.importSshFolder, symbol: MenuSymbol.importItem) {
                window.openVaultWork(.sshImport(knownHostsOnly: false), on: .keychain)
            },
        ]
    }

    func managedBlankAreaPrimaryAction() {
        guard let route = window.vaultWorkRoute, isEditableRoute(route) else { return }
        editingSession.requestTransition(route: route, action: window.closeVaultWork)
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

    private func select(_ item: Item, action: @escaping () -> Void) {
        guard let current = window.vaultWorkRoute, isEditableRoute(current) else {
            action()
            return
        }
        let target = editorRoute(for: item)
        guard current != target else {
            action()
            return
        }
        editingSession.requestTransition(route: current) {
            action()
            window.openVaultWork(target, on: .keychain)
        }
    }

    private func edit(_ item: Item, action: @escaping () -> Void) {
        let target = editorRoute(for: item)
        guard let current = window.vaultWorkRoute, isEditableRoute(current), current != target else {
            action()
            window.openVaultWork(target, on: .keychain)
            return
        }
        editingSession.requestTransition(route: current) {
            action()
            window.openVaultWork(target, on: .keychain)
        }
    }

    private func editorRoute(for item: Item) -> VaultWorkRoute {
        switch item {
        case .key(let key): .editKey(key.id)
        case .identity(let identity): .identityEditor(identity.id)
        }
    }

    private func isEditableRoute(_ route: VaultWorkRoute) -> Bool {
        switch route {
        case .editKey, .identityEditor: true
        default: false
        }
    }

    private func requestExport(_ keys: [SSHKeyRef]) {
        guard keys.count == 1, let key = keys.first else { return }
        window.openVaultWork(.exportKey(key.id), on: .keychain)
    }

    private func requestDelete(_ items: [Item]) {
        state.requestDeletion(of: items)
    }

    /// Identities go first so deleting a mixed selection never leaves a host
    /// pointing at an identity whose key was removed moments earlier. Keychain
    /// failures leave that key selected and report the first error.
    private func delete(_ items: [Item]) {
        let keys = items.compactMap(\.key)
        let identities = items.compactMap(\.identity)
        for identity in identities {
            if !app.credentials.delete(identityID: identity.id) {
                state.errorMessage =
                    app.credentials.storageError
                    ?? String(localized: AppStrings.Keychain.theIdentityCouldNotBeDeleted)
            }
        }
        for key in keys {
            do {
                try app.credentials.delete(keyID: key.id)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
        state.deleting = []
        window.pruneVaultSelections(in: app.credentials)
    }

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label(AppStrings.Keychain.keychainIsEmpty.swiftUIKey, systemImage: "key.fill")
        } description: {
            Text(
                AppStrings.Keychain.emptyDescription
            )
        } actions: {
            // The only door out of the empty state that opens yet: an identity
            // can be a username and a password, which needs no key material.
            Button(AppStrings.Keychain.newIdentity.swiftUIKey) {
                window.openVaultWork(.identityEditor(nil), on: .keychain)
            }
            Button(AppStrings.Keychain.importKey.swiftUIKey) {
                window.openVaultWork(.importKey, on: .keychain)
            }
            Button(AppStrings.Keychain.generateKey.swiftUIKey) {
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
                delete: delete,
                pruneSelection: { window.pruneVaultSelections(in: app.credentials) }
            )
        )
    }

}

struct KeychainPagePresentation: ManagedCardPresentationModifier {
    struct Actions {
        let delete: ([KeychainPageView.Item]) -> Void
        let pruneSelection: () -> Void
    }

    let state: KeychainPageState
    let actions: Actions

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
            .onAppear(perform: actions.pruneSelection)
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { !state.deleting.isEmpty },
                    set: { if !$0 { state.deleting = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                    actions.delete(state.deleting)
                }
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { state.deleting = [] }
            } message: {
                confirmationMessage
            }
            // A refused Keychain delete used to be a line of orange text in the
            // page toolbar. With the toolbar gone it needs somewhere it cannot
            // be missed: leaving a key the user asked to remove sitting there
            // with no explanation is the one outcome worth interrupting for.
            .alert(
                AppStrings.Keychain.keychainOperationFailed,
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button(AppStrings.Common.ok.swiftUIKey) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
    }

    private var confirmationTitle: Text {
        let keys = state.deleting.compactMap(\.key)
        let identities = state.deleting.compactMap(\.identity)
        if keys.count == 1, identities.isEmpty { return Text(AppStrings.Keychain.deleteKeyConfirmation) }
        if keys.count > 1, identities.isEmpty { return Text(AppStrings.Keychain.deleteKeysConfirmation(keys.count)) }
        if identities.count == 1, keys.isEmpty { return Text(AppStrings.Keychain.deleteIdentityConfirmation) }
        if identities.count > 1, keys.isEmpty {
            return Text(AppStrings.Keychain.deleteIdentitiesConfirmation(identities.count))
        }
        return Text(AppStrings.Keychain.deleteItemsConfirmation(keys.count + identities.count))
    }

    private var confirmationMessage: Text {
        let keys = state.deleting.compactMap(\.key)
        let identities = state.deleting.compactMap(\.identity)
        if keys.count == 1, identities.isEmpty {
            return Text(AppStrings.Keychain.deleteKeyWarning)
        }
        if keys.count > 1, identities.isEmpty {
            return Text(AppStrings.Keychain.deleteKeysWarning)
        }
        if identities.count == 1, keys.isEmpty {
            return Text(AppStrings.Keychain.deleteIdentityWarning)
        }
        if identities.count > 1, keys.isEmpty {
            return Text(AppStrings.Keychain.deleteIdentitiesWarning)
        }
        return Text(AppStrings.Keychain.deleteItemsWarning)
    }
}

struct KeychainImportDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        SoftwareKeyEditor(
            title: AppStrings.Keychain.importKey, symbol: "square.and.arrow.down",
            close: window.closeVaultWork,
            defaultStorage: app.newVaultKeyStorage,
            saveSecurityKey: { name, color, credential in
                var key = try WebAuthnSSH.keyReference(credential, label: name)
                key.colorTag = color
                try app.credentials.upsert(key)
                window.selectVaultItem(.key(key.id), on: .keychain)
            },
            save: save
        )
    }

    private func save(
        name: String, colorTag: TagColor, storage: KeyStorage, privateKey: String,
        passphrase: String?, savePassphrase: Bool, certificate: String, material: SSHKeyMaterial
    ) async throws -> SSHKeyRef {
        let key = SSHKeyRef(
            label: name,
            algorithm: material.algorithm, publicKey: material.publicKey,
            certificate: certificate, fingerprint: material.fingerprint,
            credentialRef: "termind.key.\(UUID().uuidString)", storage: storage,
            keySize: material.keySize, hasPassphrase: try SSHKeyMaterial.privateKeyMetadata(privateKey).isEncrypted,
            createdAt: Date(), colorTag: colorTag
        )
        try app.credentials.upsert(
            key,
            credential: .software(
                SSHPrivateKeySecret(privateKey: privateKey, passphrase: savePassphrase ? passphrase : nil)
            )
        )
        window.selectVaultItem(.key(key.id), on: .keychain)
        return key
    }
}

private struct SoftwareKeyEditor: View {
    private enum FileChoice {
        case privateKey
        case certificate
    }

    let saveSecurityKey: ((String, TagColor, SecurityKeyCredential) throws -> Void)?
    @State private var usesWebAuthn = false
    @State private var verification: SecurityKeyCredential.UserVerification = .preferred
    @State private var reference = ""
    @State private var referenceDropTask: Task<Void, Never>?
    let existing: SSHKeyRef?
    let title: LocalizedStringResource
    let symbol: String
    let close: () -> Void
    let loadPrivateKey: (() throws -> SSHPrivateKeySecret)?
    let save:
        (
            _ name: String, _ colorTag: TagColor, _ storage: KeyStorage, _ privateKey: String,
            _ passphrase: String?, _ savePassphrase: Bool, _ certificate: String, _ material: SSHKeyMaterial
        ) async throws -> SSHKeyRef
    let saveMetadata:
        ((_ name: String, _ colorTag: TagColor, _ certificate: String, _ publicKey: String) throws -> SSHKeyRef)?
    let delete: (() throws -> Void)?

    @State private var name: String
    @State private var colorTag: TagColor
    @State private var storage: KeyStorage
    @State private var privateKey = ""
    @State private var originalPrivateKey = ""
    @State private var publicKey: String
    @State private var passphrase = ""
    @State private var originalPassphrase = ""
    @State private var savePassphrase = true
    @State private var originalSavePassphrase = true
    @State private var certificate: String
    @State private var material: SSHKeyMaterial?
    @State private var isLoading: Bool
    @State private var canEditPrivateKey = true
    @State private var isChoosingFile = false
    @State private var fileChoice: FileChoice = .privateKey
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var nativeDropKind: NativeDropKind?
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(VaultWorkEditingSession.self) private var editingSession

    init(
        existing: SSHKeyRef? = nil, title: LocalizedStringResource,
        symbol: String, close: @escaping () -> Void,
        defaultStorage: KeyStorage = .iCloud,
        saveSecurityKey: ((String, TagColor, SecurityKeyCredential) throws -> Void)? = nil,
        loadPrivateKey: (() throws -> SSHPrivateKeySecret)? = nil,
        saveMetadata: (
            (_ name: String, _ colorTag: TagColor, _ certificate: String, _ publicKey: String) throws -> SSHKeyRef
        )? = nil,
        delete: (() throws -> Void)? = nil,
        save:
            @escaping (
                String, TagColor, KeyStorage, String, String?, Bool, String, SSHKeyMaterial
            ) async throws -> SSHKeyRef
    ) {
        self.saveSecurityKey = saveSecurityKey
        self.existing = existing
        self.title = title
        self.symbol = symbol
        self.close = close
        self.loadPrivateKey = loadPrivateKey
        self.saveMetadata = saveMetadata
        self.delete = delete
        self.save = save
        _name = State(initialValue: existing?.label ?? "")
        _colorTag = State(initialValue: existing?.colorTag ?? .none)
        _storage = State(initialValue: existing?.storage ?? defaultStorage)
        _certificate = State(initialValue: existing?.certificate ?? "")
        _publicKey = State(initialValue: existing?.publicKey ?? "")
        _isLoading = State(initialValue: loadPrivateKey != nil)
    }

    var body: some View {
        VaultDetailScaffold(
            title: title, symbol: symbol,
            close: {
                if existing == nil { close() } else { cancelEditing() }
            },
            closeLabel: existing == nil ? AppStrings.Common.close : AppStrings.Common.cancel
        ) {
            if isLoading {
                ProgressView(AppStrings.Keychain.loadingPrivateKeyProgress.swiftUIKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        VaultNameField(text: $name, prompt: Text(verbatim: defaultName))
                        VaultColorField(selection: $colorTag)
                    }

                    Section {
                        KeyCreationStoragePicker(
                            storage: $storage, usesWebAuthn: $usesWebAuthn,
                            allowsWebAuthn: existing == nil && saveSecurityKey != nil
                        )
                        .disabled(!canEditPrivateKey || existing?.storage == .iCloud)
                        if usesWebAuthn {
                            WebAuthnVerificationPicker(selection: $verification)
                            keyTextEditor(
                                text: $reference, minHeight: 150, placeholder: AppStrings.SecurityKey.importHelp
                            )
                            .accessibilityLabel(AppStrings.SecurityKey.reference.swiftUIKey)
                            .onDrop(of: [.plainText], isTargeted: nil, perform: receiveReferenceText)
                        } else {
                            keyTextEditor(
                                text: $privateKey, minHeight: 150,
                                placeholder: AppStrings.Keychain.pasteAPrivateKeyOrDragOneIn
                            )
                            .accessibilityLabel(AppStrings.Keychain.privateKey.swiftUIKey)
                            .disabled(!canEditPrivateKey)
                            if let existing, let material,
                                material.publicKey != existing.publicKey
                            {
                                Label(
                                    AppStrings.Keychain.replacePrivateKeyWarning.swiftUIKey,
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            if privateKeyRequiresPassphrase {
                                RevealableSecretField(
                                    AppStrings.Keychain.passphrase, text: $passphrase,
                                    prompt: Text(AppStrings.Common.optional)
                                )
                                .disabled(!canEditPrivateKey)
                                Toggle(AppStrings.Keychain.savePassphrase.swiftUIKey, isOn: $savePassphrase)
                                    .disabled(!canEditPrivateKey)
                            }
                        }
                    } header: {
                        fileSectionHeader(
                            usesWebAuthn ? AppStrings.SecurityKey.reference : AppStrings.Keychain.privateKey,
                            canChoose: canEditPrivateKey
                        ) {
                            chooseFile(for: .privateKey)
                        }
                    }

                    if !usesWebAuthn {
                        Section(AppStrings.Keychain.publicKey.swiftUIKey) {
                            keyTextEditor(
                                text: $publicKey, minHeight: 100, placeholder: AppStrings.KeyExport.optionalPublicKey
                            )
                            .accessibilityLabel(AppStrings.Keychain.publicKey.swiftUIKey)
                        }

                        Section {
                            keyTextEditor(
                                text: $certificate, minHeight: 110,
                                placeholder: AppStrings.Keychain.certificateOptional
                            )
                            .accessibilityLabel(AppStrings.Keychain.certificate.swiftUIKey)
                            if let warning = certificateWarning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } header: {
                            fileSectionHeader(AppStrings.Keychain.certificate) { chooseFile(for: .certificate) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } footer: {
            HStack(spacing: Metrics.Space.m) {
                if existing != nil, delete != nil {
                    Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) { confirmsDeletion = true }
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(AppStrings.Common.cancel.swiftUIKey) {
                    if existing == nil { close() } else { cancelEditing() }
                }
                Button(existing == nil ? AppStrings.Common.import.swiftUIKey : AppStrings.Common.save.swiftUIKey) {
                    Task {
                        guard await commitChanges() else { return }
                        close()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isWorking || isLoading
                        || (canEditPrivateKey
                            && (usesWebAuthn
                                ? reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                : privateKey.isEmpty))
                )
            }
            .padding()
        }
        .fileImporter(
            isPresented: $isChoosingFile, allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false, onCompletion: receiveFiles
        )
        .overlay {
            if nativeDropKind != nil {
                DropTargetOverlay(presentation: dropPresentation)
            }
        }
        .overlay {
            NativeDropTarget(
                targetedKind: $nativeDropKind,
                acceptedKinds: [.files],
                isEnabled: canEditPrivateKey && !isLoading && !isWorking,
                receive: { payload in receive(urls: payload.fileURLs) }
            )
        }
        .animation(
            Motion.dropTarget(reduceMotion: reduceMotion),
            value: nativeDropKind
        )
        .task {
            load()
            guard let existing else { return }
            editingToken = editingSession.register(
                route: .editKey(existing.id), isDirty: { isDirty }
            ) {
                await commitChanges()
            }
        }
        .onChange(of: reference) { _, value in
            if let credential = try? WebAuthnSSH.importReference(value) {
                verification = credential.userVerification
            }
        }
        .onChange(of: privateKey) { old, value in
            if !isLoading, !originalPrivateKey.isEmpty, value != originalPrivateKey, publicKey == existing?.publicKey {
                publicKey = ""
            }
            if value != originalPrivateKey, old == originalPrivateKey, !originalPassphrase.isEmpty {
                passphrase = ""
            }
        }
        .onDisappear {
            referenceDropTask?.cancel()
            privateKey = ""
            originalPrivateKey = ""
            passphrase = ""
            originalPassphrase = ""
            material = nil
            isLoading = loadPrivateKey != nil
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog(
            AppStrings.Keychain.deleteKeyConfirmation, isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Keychain.deleteKey.swiftUIKey, role: .destructive, action: deleteKey)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Keychain.deleteKeyWarning)
        }
        .task(id: validationToken) { refreshPublicMaterial() }
    }

    /// A key blob field drawn on the form's own background.
    ///
    /// `TextEditor` brings its own opaque control background, which inside a
    /// grouped `Form` reads as a white card sitting on the section rather than
    /// as part of it. Hiding it puts these two fields on the same footing as the
    /// skill editor's, which is the surface this one is measured against.
    ///
    /// The prompt is the price of that: `TextEditor` has no `prompt:`, and once
    /// the box is gone an empty field is an unmarked gap in the form instead of
    /// a visibly empty box. It matches the editor's font so the first typed
    /// character lands exactly where the prompt started.
    private func keyTextEditor(
        text: Binding<String>, minHeight: CGFloat, placeholder: LocalizedStringResource
    ) -> some View {
        TextEditor(text: text)
            .font(.caption.monospaced())
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.textInset)
                        .allowsHitTesting(false)
                }
            }
    }

    /// `TextEditor`'s own text-container inset, which the prompt has to match or
    /// the first typed character lands somewhere else than the prompt did.
    ///
    /// Only leading: the container is inset by its line fragment padding
    /// horizontally and by nothing vertically, so the top padding this used to
    /// carry pushed the prompt a line below the caret it was standing in for.
    /// Same value the composer prompt in `ConversationViews` uses.
    private static let textInset: CGFloat = 5

    /// The section title with its file picker at the trailing edge.
    ///
    /// The button used to head a row of its own, next to a label repeating the
    /// section title. With the editor no longer drawn as a box, that row had
    /// nothing left to attach to and read as a second heading.
    private func fileSectionHeader(
        _ title: LocalizedStringResource, canChoose: Bool = true, choose: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(AppStrings.Common.choose.swiftUIKey, action: choose)
                .disabled(!canChoose)
        }
    }

    @MainActor
    private var isDirty: Bool {
        guard let existing else {
            return !name.isEmpty || !privateKey.isEmpty || !publicKey.isEmpty || !certificate.isEmpty
        }
        return name != existing.label || colorTag != existing.colorTag || storage != existing.storage
            || privateKey != originalPrivateKey || passphrase != originalPassphrase
            || savePassphrase != originalSavePassphrase
            || publicKey != existing.publicKey || certificate != existing.certificate
    }

    private func cancelEditing() {
        guard let existing else {
            close()
            return
        }
        editingSession.requestTransition(route: .editKey(existing.id), action: close)
    }

    private func commitChanges() async -> Bool {
        guard existing == nil || isDirty else { return true }
        isWorking = true
        errorMessage = nil
        do {
            if usesWebAuthn, let saveSecurityKey {
                var credential = try WebAuthnSSH.importReference(reference)
                credential.userVerification = verification
                try WebAuthnSSH.validate(credential)
                try saveSecurityKey(name, colorTag, credential)
                isWorking = false
                return true
            }
            let normalizedCertificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !canEditPrivateKey, existing != nil, let saveMetadata {
                if !normalizedCertificate.isEmpty {
                    _ = try SSHUserCertificate.parse(
                        normalizedCertificate, matching: publicKey.isEmpty ? nil : publicKey)
                }
                _ = try saveMetadata(
                    name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, normalizedCertificate, publicKey
                )
                isWorking = false
                return true
            }
            let passphrase = privateKeyRequiresPassphrase && !passphrase.isEmpty ? passphrase : nil
            let savesPassphrase = savePassphrase && passphrase != nil
            let inspected = try SSHKeyMaterial.imported(privateKey: privateKey, publicKey: publicKey)
            if !normalizedCertificate.isEmpty {
                _ = try SSHUserCertificate.parse(
                    normalizedCertificate, matching: inspected.publicKey.isEmpty ? nil : inspected.publicKey
                )
            }
            _ = try await save(
                name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, storage,
                privateKey, passphrase, savesPassphrase, normalizedCertificate, inspected
            )
            savePassphrase = savesPassphrase
            isWorking = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
            return false
        }
    }

    private func deleteKey() {
        do {
            try delete?()
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var validationToken: String { privateKey + "\u{0}" + publicKey }

    private var privateKeyRequiresPassphrase: Bool {
        (try? SSHKeyMaterial.privateKeyMetadata(privateKey).isEncrypted) == true
    }

    private var defaultName: String {
        if usesWebAuthn { return String(localized: AppStrings.SecurityKey.title) }
        let algorithm =
            material?.privateKey == privateKey
            ? material?.algorithm : privateKey == originalPrivateKey ? existing?.algorithm : nil
        guard let algorithm else { return "" }
        return SSHKeyRef.defaultName(algorithm: algorithm, storage: storage)
    }

    private var dropPresentation: DropTargetPresentation {
        DropTargetPresentation(
            title: existing == nil
                ? String(localized: AppStrings.Common.dragToImport)
                : String(localized: AppStrings.Keychain.dragToReplace),
            detail: String(
                localized: usesWebAuthn ? AppStrings.SecurityKey.reference : AppStrings.Keychain.privateKeyOrCertificate
            ),
            systemImage: "key.fill"
        )
    }

    private var certificateWarning: String? {
        guard !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try SSHUserCertificate.parse(
                certificate, matching: publicKey.isEmpty ? nil : publicKey
            ).validityWarning
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    private func load() {
        guard isLoading else { return }
        do {
            let secret = try loadPrivateKey?()
            privateKey = secret?.privateKey ?? ""
            originalPrivateKey = privateKey
            passphrase = secret?.passphrase ?? ""
            originalPassphrase = passphrase
            savePassphrase = !passphrase.isEmpty
            originalSavePassphrase = savePassphrase
        } catch {
            errorMessage = error.localizedDescription
            canEditPrivateKey = false
            privateKey = ""
            originalPrivateKey = ""
        }
        isLoading = false
    }

    private func refreshPublicMaterial() {
        material = try? SSHKeyMaterial.imported(privateKey: privateKey, publicKey: publicKey)
    }

    private func receiveReferenceText(_ providers: [NSItemProvider]) -> Bool {
        guard usesWebAuthn, !isWorking, let provider = providers.first else { return false }
        referenceDropTask?.cancel()
        referenceDropTask = Task {
            do {
                let text = try await ReferenceDropLoader.load(provider)
                _ = try WebAuthnSSH.importReference(text)
                try Task.checkCancellation()
                guard usesWebAuthn, !isWorking else { return }
                reference = text
                errorMessage = nil
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
        return true
    }

    private func receiveFiles(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            if usesWebAuthn {
                reference = try WebAuthnSSH.readReferenceFile(url)
                errorMessage = nil
                return
            }
            let imported = try SoftwareKeyFileImporter.read(
                urls: [url],
                infersName: fileChoice == .privateKey
                    && SoftwareKeyFileImporter.shouldInferName(from: name)
            )
            switch fileChoice {
            case .privateKey:
                guard let importedPrivateKey = imported.privateKey else {
                    throw SoftwareKeyFileImporter.unexpectedFileError()
                }
                privateKey = importedPrivateKey
                if let inferredName = imported.inferredName { name = inferredName }
            case .certificate:
                guard let importedCertificate = imported.certificate else {
                    throw SoftwareKeyFileImporter.unexpectedFileError()
                }
                certificate = importedCertificate
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseFile(for choice: FileChoice) {
        fileChoice = choice
        isChoosingFile = true
    }

    @discardableResult
    private func receive(urls: [URL]) -> Bool {
        do {
            guard !urls.isEmpty else { return false }
            if usesWebAuthn, let url = urls.first {
                reference = try WebAuthnSSH.readReferenceFile(url)
                errorMessage = nil
                return true
            }
            let result = try SoftwareKeyFileImporter.read(
                urls: urls,
                infersName: SoftwareKeyFileImporter.shouldInferName(from: name)
            )
            if let importedPrivateKey = result.privateKey { privateKey = importedPrivateKey }
            if let importedCertificate = result.certificate { certificate = importedCertificate }
            if let inferredName = result.inferredName { name = inferredName }
            errorMessage = nil
            return result.privateKey != nil || result.certificate != nil
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
        GenerateKeySheet(
            credentials: app.credentials,
            defaultStorage: app.newVaultKeyStorage,
            generate: generate,
            selectKey: { window.selectVaultItem(.key($0.id), on: .keychain) },
            close: window.closeVaultWork)
    }

    private func generate(
        label: String, colorTag: TagColor, generation: SSHKeyMaterial.Generation, passphrase: String?,
        savePassphrase: Bool,
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
                    SSHPrivateKeySecret(privateKey: material.privateKey, passphrase: savePassphrase ? passphrase : nil)
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

    let credentials: CredentialLibraryModel
    let selectKey: (SSHKeyRef) -> Void
    @State private var usesWebAuthn = false
    @State private var verification: SecurityKeyCredential.UserVerification = .preferred
    @State private var presenter = SecurityKeyPresenter()
    @State private var generationTask: Task<Void, Never>?
    let generate:
        (
            String, TagColor, SSHKeyMaterial.Generation, String?, Bool, SSHKeyMaterial.Cipher, Int,
            KeyStorage, Bool
        ) async throws -> SSHKeyRef
    let close: () -> Void

    @State private var label = ""
    @State private var colorTag = TagColor.none
    @State private var storage: KeyStorage
    @State private var kind = Kind.ed25519
    @State private var curveBits = 256
    @State private var rsaBits = 3072
    @State private var passphrase = ""
    @State private var savePassphrase = true
    @State private var confirmation = ""
    @State private var cipher = SSHKeyMaterial.Cipher.aes256
    @State private var rounds = 100
    @State private var requiresUserPresence = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        credentials: CredentialLibraryModel,
        defaultStorage: KeyStorage = .iCloud,
        generate:
            @escaping (
                String, TagColor, SSHKeyMaterial.Generation, String?, Bool, SSHKeyMaterial.Cipher, Int,
                KeyStorage, Bool
            ) async throws -> SSHKeyRef,
        selectKey: @escaping (SSHKeyRef) -> Void,
        close: @escaping () -> Void
    ) {
        self.credentials = credentials
        self.selectKey = selectKey
        self.generate = generate
        self.close = close
        _storage = State(initialValue: defaultStorage)
    }

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
        VaultDetailScaffold(title: AppStrings.Keychain.generateKey, symbol: "key.fill", close: close) {
            Form {
                Section {
                    VaultNameField(text: $label, prompt: Text(defaultName))
                    VaultColorField(selection: $colorTag)
                }
                Section(
                    !usesWebAuthn && storage == .secureEnclave
                        ? AppStrings.Keychain.secureEnclave.swiftUIKey : AppStrings.Keychain.privateKey.swiftUIKey
                ) {
                    KeyCreationStoragePicker(
                        storage: $storage, usesWebAuthn: $usesWebAuthn,
                        allowsSecureEnclave: true, secureEnclaveAvailable: SecureEnclaveKey.isAvailable
                    )
                    if usesWebAuthn {
                        WebAuthnVerificationPicker(selection: $verification)
                    } else if storage == .secureEnclave {
                        LabeledContent(AppStrings.Keychain.algorithm.swiftUIKey, value: "ECDSA")
                        LabeledContent(
                            AppStrings.Keychain.ellipticCurve.swiftUIKey,
                            value: String(localized: AppStrings.Keychain.nistP256))
                        Toggle(AppStrings.Keychain.requireAuthentication.swiftUIKey, isOn: $requiresUserPresence)
                    } else {
                        Picker(AppStrings.Keychain.algorithm.swiftUIKey, selection: $kind) {
                            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if kind == .ecdsa {
                            Picker(AppStrings.Keychain.ellipticCurve.swiftUIKey, selection: $curveBits) {
                                Text(AppStrings.Keychain.nistP256).tag(256)
                                Text(AppStrings.Keychain.nistP384).tag(384)
                                Text(AppStrings.Keychain.nistP521).tag(521)
                            }
                        } else if kind == .rsa {
                            Picker(AppStrings.Keychain.keySize.swiftUIKey, selection: $rsaBits) {
                                Text(AppStrings.Keychain.rsa2048Bits).tag(2048)
                                Text(AppStrings.Keychain.rsa3072Bits).tag(3072)
                                Text(AppStrings.Keychain.rsa4096Bits).tag(4096)
                            }
                        }
                        RevealableSecretField(
                            AppStrings.Keychain.passphrase, text: $passphrase,
                            prompt: Text(AppStrings.Common.optional))
                        RevealableSecretField(AppStrings.Keychain.confirmPassphrase, text: $confirmation)
                            .disabled(passphrase.isEmpty)
                        Toggle(AppStrings.Keychain.savePassphrase.swiftUIKey, isOn: $savePassphrase)
                        if !passphrase.isEmpty {
                            Picker(AppStrings.Keychain.cipher.swiftUIKey, selection: $cipher) {
                                ForEach(SSHKeyMaterial.Cipher.allCases) { cipher in
                                    Text(cipher.displayName).tag(cipher)
                                }
                            }
                            TextField(AppStrings.Keychain.rounds.swiftUIKey, value: $rounds, format: .number)
                                .lineLimit(1)
                        }
                        if !passwordsMatch {
                            Text(AppStrings.Keychain.passphrasesDoNotMatch)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
        } footer: {
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(AppStrings.Common.cancel.swiftUIKey, action: close).keyboardShortcut(.cancelAction)
                Button(AppStrings.Keychain.generate.swiftUIKey) {
                    generationTask = Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isWorking
                        || (!usesWebAuthn && storage != .secureEnclave
                            && (!passwordsMatch || (!passphrase.isEmpty && rounds <= 0)))
                        || (!usesWebAuthn && storage == .secureEnclave && !SecureEnclaveKey.isAvailable)
                )
            }
            .padding()
        }
        .background(SecurityKeyAnchor(presenter: presenter).frame(width: 0, height: 0))
        .onDisappear {
            generationTask?.cancel()
            presenter.cancel()
            passphrase = ""
            confirmation = ""
        }
    }

    @MainActor
    private func commit() async {
        isWorking = true
        errorMessage = nil
        do {
            if usesWebAuthn {
                let credential = try await presenter.register(
                    name: label.isEmpty ? "Termind" : label, userVerification: verification)
                try WebAuthnSSH.validate(credential)
                try Task.checkCancellation()
                var key = try WebAuthnSSH.keyReference(
                    credential, label: label)
                key.colorTag = colorTag
                try credentials.upsert(key)
                selectKey(key)
            } else {
                let savesPassphrase = savePassphrase && !passphrase.isEmpty
                _ = try await generate(
                    label.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, generation,
                    storage == .secureEnclave || passphrase.isEmpty ? nil : passphrase,
                    savesPassphrase, cipher, rounds, storage,
                    storage == .secureEnclave && requiresUserPresence
                )
                savePassphrase = savesPassphrase
            }
            passphrase = ""
            confirmation = ""
            close()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    private var defaultName: String {
        if usesWebAuthn { return String(localized: AppStrings.SecurityKey.title) }
        let algorithm: SSHKeyAlgorithm =
            switch kind {
            case .ed25519: .ed25519
            case .ecdsa: .ecdsa256
            case .rsa: .rsa
            }
        return SSHKeyRef.defaultName(algorithm: algorithm, storage: storage)
    }
}

struct KeychainEditDetail: View {
    let keyID: SSHKeyRef.ID

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @ViewBuilder
    var body: some View {
        if let key = app.credentials.key(keyID) {
            if key.algorithm == .securityKey {
                SecurityKeyEditor(credentials: app.credentials, existing: key, close: window.closeVaultWork)
            } else if key.storage == .secureEnclave {
                SecureEnclaveKeyEditor(
                    key: key, close: window.closeVaultWork,
                    delete: { try delete(key) },
                    save: { name, colorTag in
                        try saveSecureEnclave(key, name: name, colorTag: colorTag)
                    }
                )
            } else {
                SoftwareKeyEditor(
                    existing: key, title: AppStrings.Keychain.editKey, symbol: "pencil",
                    close: window.closeVaultWork,
                    loadPrivateKey: { try loadPrivateKey(key) },
                    saveMetadata: { name, colorTag, certificate, publicKey in
                        try saveSoftwareKeyMetadata(
                            key, name: name, colorTag: colorTag, certificate: certificate, publicKey: publicKey
                        )
                    },
                    delete: { try delete(key) },
                    save: {
                        name, colorTag, storage, privateKey, passphrase, savePassphrase, certificate, material in
                        try await saveSoftwareKey(
                            key, name: name, colorTag: colorTag, storage: storage,
                            privateKey: privateKey, passphrase: passphrase, savePassphrase: savePassphrase,
                            certificate: certificate, material: material
                        )
                    }
                )
            }
        } else {
            ContentUnavailableView(AppStrings.Keychain.keyUnavailable.swiftUIKey, systemImage: "key.slash")
        }
    }

    private func loadPrivateKey(_ key: SSHKeyRef) throws -> SSHPrivateKeySecret {
        guard case .software(let secret)? = try app.credentials.keyCredential(for: key) else {
            throw TermindSSHError.library(
                String(localized: AppStrings.Keychain.thePrivateKeyIsUnavailableOnThisMac)
            )
        }
        return secret
    }

    private func delete(_ key: SSHKeyRef) throws {
        try app.credentials.delete(keyID: key.id)
        window.pruneVaultSelections(in: app.credentials)
    }

    private func saveSoftwareKey(
        _ original: SSHKeyRef, name: String, colorTag: TagColor, storage: KeyStorage,
        privateKey: String, passphrase: String?, savePassphrase: Bool, certificate: String,
        material: SSHKeyMaterial
    ) async throws -> SSHKeyRef {
        var updated = original
        updated.label = name
        updated.colorTag = colorTag
        updated.storage = storage
        updated.algorithm = material.algorithm
        updated.publicKey = material.publicKey
        updated.certificate = certificate
        updated.fingerprint = material.fingerprint
        updated.keySize = material.keySize
        updated.hasPassphrase = try SSHKeyMaterial.privateKeyMetadata(privateKey).isEncrypted
        try app.credentials.upsert(
            updated,
            credential: .software(
                SSHPrivateKeySecret(privateKey: privateKey, passphrase: savePassphrase ? passphrase : nil)
            )
        )
        window.selectVaultItem(.key(updated.id), on: .keychain)
        return updated
    }

    private func saveSoftwareKeyMetadata(
        _ original: SSHKeyRef, name: String, colorTag: TagColor, certificate: String, publicKey: String
    ) throws -> SSHKeyRef {
        var updated = original
        updated.label = name
        updated.colorTag = colorTag
        if publicKey != original.publicKey {
            let material = publicKey.isEmpty ? nil : try SSHKeyMaterial.publicMaterial(publicKey)
            updated.publicKey = material?.publicKey ?? ""
            updated.fingerprint = material?.fingerprint ?? ""
            updated.algorithm = material?.algorithm ?? updated.algorithm
            updated.keySize = material?.keySize ?? updated.keySize
        }
        updated.certificate = certificate
        try app.credentials.upsert(updated)
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
    let delete: () throws -> Void
    let save: (String, TagColor) throws -> Void

    @State private var name: String
    @State private var colorTag: TagColor
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?
    @Environment(VaultWorkEditingSession.self) private var editingSession

    init(
        key: SSHKeyRef, close: @escaping () -> Void, delete: @escaping () throws -> Void,
        save: @escaping (String, TagColor) throws -> Void
    ) {
        self.key = key
        self.close = close
        self.delete = delete
        self.save = save
        _name = State(initialValue: key.label)
        _colorTag = State(initialValue: key.colorTag)
    }

    var body: some View {
        VaultDetailScaffold(
            title: AppStrings.Keychain.editKey, symbol: "pencil", close: cancelEditing,
            closeLabel: AppStrings.Common.cancel
        ) {
            Form {
                Section {
                    VaultNameField(text: $name, prompt: Text(verbatim: key.defaultName))
                    VaultColorField(selection: $colorTag)
                }
                Section(AppStrings.Keychain.secureEnclave.swiftUIKey) {
                    LabeledContent(AppStrings.Keychain.storeIn.swiftUIKey) {
                        Label(key.storage.displayName, systemImage: key.storage.symbol)
                    }
                    LabeledContent(AppStrings.Keychain.algorithm.swiftUIKey, value: key.algorithm.displayName)
                    LabeledContent(AppStrings.KnownHosts.fingerprint.swiftUIKey) {
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent(AppStrings.Keychain.publicKey.swiftUIKey) {
                        Text(key.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill") }
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack(spacing: Metrics.Space.m) {
                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) { confirmsDeletion = true }
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey, action: cancelEditing)
                Button(AppStrings.Common.save.swiftUIKey, action: saveAndClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .onAppear {
            editingToken = editingSession.register(
                route: .editKey(key.id), isDirty: { isDirty }
            ) { commitChanges() }
        }
        .onDisappear {
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog(
            AppStrings.Keychain.deleteKeyConfirmation, isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Keychain.deleteKey.swiftUIKey, role: .destructive, action: deleteKey)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Keychain.deleteKeyWarning)
        }
    }

    private var isDirty: Bool { name != key.label || colorTag != key.colorTag }

    private func cancelEditing() {
        editingSession.requestTransition(route: .editKey(key.id), action: close)
    }

    private func commitChanges() -> Bool {
        guard isDirty else { return true }
        do {
            try save(name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func saveAndClose() {
        guard commitChanges() else { return }
        close()
    }

    private func deleteKey() {
        do {
            try delete()
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Export to hosts

/// Installs one or more public keys on several saved destinations. A checked row is an
/// explicit authorization to change that account's `authorized_keys`; opening
/// the sheet never inherits the Keychain card selection as a host selection.
// MARK: - Key card

/// The singular actions for one key, shared by its card and editor surfaces.
/// Card actions never resolve secret material; Edit is the explicit boundary
/// that loads a software key from Keychain.
struct KeyObjectActions: View {
    let key: SSHKeyRef
    let edit: () -> Void
    let export: () -> Void

    var body: some View {
        Button(AppStrings.Keychain.exportToHost.swiftUIKey, systemImage: MenuSymbol.export, action: export)
        Divider()
        Menu(AppStrings.Common.copy.swiftUIKey, systemImage: MenuSymbol.copy) {
            Button(AppStrings.Keychain.publicKey.swiftUIKey, systemImage: "key") {
                copyToPasteboard(key.publicKey)
            }
            .disabled(key.publicKey.isEmpty)
            Button(AppStrings.KnownHosts.fingerprint.swiftUIKey, systemImage: "touchid") {
                copyToPasteboard(key.fingerprint)
            }
            .disabled(key.publicKey.isEmpty || key.fingerprint.isEmpty)
        }
        Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit, action: edit)
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

                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.label)
                            .font(.headline)
                            .lineLimit(1)
                        Text(
                            key.algorithm == .unknown
                                ? AppStrings.Keychain.unknownKeyType : AppStrings.Keychain.keyType(keyDisplayName)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: Metrics.Space.xs) {
                    if key.hasPassphrase {
                        CardChip(
                            text: String(
                                localized: app.credentials.hasSavedPassphrase(for: key)
                                    ? AppStrings.Keychain.passphraseSaved : AppStrings.Keychain.passphraseRequired),
                            symbol: "lock.fill"
                        )
                    }
                    CardChip(
                        text: key.algorithm == .securityKey
                            ? String(localized: AppStrings.SecurityKey.title) : key.storage.displayName,
                        symbol: key.algorithm == .securityKey ? "key.radiowaves.forward.fill" : key.storage.symbol
                    )
                    switch app.credentials.keyAvailability(for: key) {
                    case .missing:
                        CardChip(
                            text: String(localized: AppStrings.Keychain.privateKeyMissing),
                            symbol: "exclamationmark.triangle.fill", tint: .orange
                        )
                    case .failed:
                        CardChip(
                            text: String(localized: AppStrings.Keychain.keychainUnavailable),
                            symbol: "exclamationmark.triangle.fill", tint: .orange
                        )
                    case .available, .notConfigured:
                        EmptyView()
                    }

                    Spacer(minLength: Metrics.Space.xs)

                    if dependents > 0 {
                        Text(AppStrings.Keychain.identityCount(dependents))
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
            }
            Divider()
            DestructiveMenuButton(AppStrings.Common.delete, action: delete)
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
        Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit, action: edit)
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
                        modifiedAt
                            .map { $0.formatted(.relative(presentation: .numeric)) }
                            ?? String(localized: AppStrings.SFTP.unknown)
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
            Divider()
            DestructiveMenuButton(AppStrings.Common.delete, action: delete)
        }
        .help(Text(identity.notes.isEmpty ? identity.username : identity.notes))
    }

    private var modifiedAt: Date? {
        guard let date = app.credentials.identityModifiedAt(identity.id),
            date > VaultVersion.baselineDate
        else { return nil }
        return date
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
                CardChip(text: String(localized: AppStrings.Vault.password), symbol: "lock.fill")
            case .missing:
                CardChip(
                    text: String(localized: AppStrings.Keychain.passwordMissing),
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
            case .failed:
                CardChip(
                    text: String(localized: AppStrings.Keychain.passwordUnavailable),
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
            case .notConfigured:
                EmptyView()
            }
            CardChip(
                text: identity.passwordStorage.displayName,
                symbol: identity.passwordStorage.symbol
            )
        }

        if identity.usesKey {
            if let key {
                CardChip(
                    text: key.label, symbol: "key.fill",
                    tint: key.colorTag.color ?? TermindColor.accent
                )
            } else {
                CardChip(
                    text: String(localized: AppStrings.Keychain.keyMissing),
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }

        if !identity.hasSecret {
            CardChip(text: String(localized: AppStrings.Keychain.noSecret), symbol: "questionmark.circle")
        }
    }
}
