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
        guard !keys.isEmpty else { return }
        window.openVaultWork(.exportKeys(keys.map(\.id)), on: .keychain)
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
                AppStrings.Keychain.keychainOperationFailed.swiftUIKey,
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
            save: save
        )
    }

    private func save(
        name: String, colorTag: TagColor, storage: KeyStorage, privateKey: String,
        passphrase: String?, certificate: String, material: SSHKeyMaterial
    ) async throws -> SSHKeyRef {
        let key = SSHKeyRef(
            label: name,
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
    private enum FileChoice {
        case privateKey
        case certificate
    }

    let existing: SSHKeyRef?
    let title: LocalizedStringResource
    let symbol: String
    let close: () -> Void
    let loadPrivateKey: (() throws -> String)?
    let save:
        (
            _ name: String, _ colorTag: TagColor, _ storage: KeyStorage, _ privateKey: String,
            _ passphrase: String?, _ certificate: String, _ material: SSHKeyMaterial
        ) async throws -> SSHKeyRef
    let saveMetadata: ((_ name: String, _ colorTag: TagColor, _ certificate: String) throws -> SSHKeyRef)?
    let delete: (() throws -> Void)?

    @State private var name: String
    @State private var colorTag: TagColor
    @State private var storage: KeyStorage
    @State private var privateKey = ""
    @State private var originalPrivateKey = ""
    @State private var passphrase = ""
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
        loadPrivateKey: (() throws -> String)? = nil,
        saveMetadata: ((_ name: String, _ colorTag: TagColor, _ certificate: String) throws -> SSHKeyRef)? = nil,
        delete: (() throws -> Void)? = nil,
        save:
            @escaping (
                String, TagColor, KeyStorage, String, String?, String, SSHKeyMaterial
            ) async throws -> SSHKeyRef
    ) {
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
                        Picker(AppStrings.Keychain.storeIn.swiftUIKey, selection: $storage) {
                            Label(AppStrings.Keychain.iCloud.swiftUIKey, systemImage: "icloud.fill").tag(
                                KeyStorage.iCloud)
                            Label(AppStrings.Keychain.thisMac.swiftUIKey, systemImage: "lock.laptopcomputer")
                                .tag(KeyStorage.thisDevice)
                        }
                        .disabled(!canEditPrivateKey || existing?.storage == .iCloud)
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
                        RevealableSecretField(
                            AppStrings.Keychain.passphrase, text: $passphrase,
                            prompt: Text(AppStrings.Common.optional)
                        )
                        .disabled(!canEditPrivateKey)
                    } header: {
                        fileSectionHeader(AppStrings.Keychain.privateKey, canChoose: canEditPrivateKey) {
                            chooseFile(for: .privateKey)
                        }
                    }

                    Section(AppStrings.Keychain.publicKey.swiftUIKey) {
                        Text(publicKeyDisplay)
                            .font(.caption.monospaced())
                            .foregroundStyle(material == nil ? .secondary : .primary)
                            .textSelection(.enabled)
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
                .disabled(isWorking || isLoading || (canEditPrivateKey && privateKey.isEmpty))
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
        .task(id: validationToken) { await derivePublicMaterial() }
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
        guard let existing else { return !name.isEmpty || !privateKey.isEmpty || !certificate.isEmpty }
        return name != existing.label || colorTag != existing.colorTag || storage != existing.storage
            || privateKey != originalPrivateKey || !passphrase.isEmpty || certificate != existing.certificate
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
            let normalizedCertificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !canEditPrivateKey, let existing, let saveMetadata {
                if !normalizedCertificate.isEmpty {
                    _ = try SSHUserCertificate.parse(normalizedCertificate, matching: existing.publicKey)
                }
                _ = try saveMetadata(
                    name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, normalizedCertificate
                )
                isWorking = false
                return true
            }
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
            if !normalizedCertificate.isEmpty {
                _ = try SSHUserCertificate.parse(
                    normalizedCertificate, matching: inspected.publicKey
                )
            }
            _ = try await save(
                name.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, storage,
                privateKey, passphrase, normalizedCertificate, inspected
            )
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

    private var validationToken: String { privateKey + "\u{0}" + passphrase }

    private var defaultName: String {
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
            detail: String(localized: AppStrings.Keychain.privateKeyOrCertificate),
            systemImage: "key.fill"
        )
    }

    private var publicKeyDisplay: String {
        material?.publicKey ?? existing?.publicKey ?? String(localized: AppStrings.Keychain.derivedFromThePrivateKey)
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
            canEditPrivateKey = false
            privateKey = ""
            originalPrivateKey = ""
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
            guard let url = try result.get().first else { return }
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
            defaultStorage: app.newVaultKeyStorage,
            generate: generate,
            close: window.closeVaultWork)
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
    @State private var storage: KeyStorage
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

    init(
        defaultStorage: KeyStorage = .iCloud,
        generate:
            @escaping (
                String, TagColor, SSHKeyMaterial.Generation, String?, SSHKeyMaterial.Cipher, Int,
                KeyStorage, Bool
            ) async throws -> SSHKeyRef,
        close: @escaping () -> Void
    ) {
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
                    storage == .secureEnclave
                        ? AppStrings.Keychain.secureEnclave.swiftUIKey : AppStrings.Keychain.privateKey.swiftUIKey
                ) {
                    Picker(AppStrings.Keychain.storeIn.swiftUIKey, selection: $storage) {
                        ForEach(availableStorage) { location in
                            Label(location.displayName, systemImage: location.symbol)
                                .tag(location)
                                .disabled(location == .secureEnclave && !SecureEnclaveKey.isAvailable)
                        }
                    }
                    if storage == .secureEnclave {
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
        } footer: {
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(AppStrings.Common.cancel.swiftUIKey, action: close).keyboardShortcut(.cancelAction)
                Button(AppStrings.Keychain.generate.swiftUIKey) {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isWorking
                        || (storage != .secureEnclave && (!passwordsMatch || (!passphrase.isEmpty && rounds <= 0)))
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
                label.trimmingCharacters(in: .whitespacesAndNewlines), colorTag, generation,
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

    private var defaultName: String {
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
            if key.storage == .secureEnclave {
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
                    saveMetadata: { name, colorTag, certificate in
                        try saveSoftwareKeyMetadata(
                            key, name: name, colorTag: colorTag, certificate: certificate
                        )
                    },
                    delete: { try delete(key) },
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
            ContentUnavailableView(AppStrings.Keychain.keyUnavailable.swiftUIKey, systemImage: "key.slash")
        }
    }

    private func loadPrivateKey(_ key: SSHKeyRef) throws -> String {
        guard case .software(let secret)? = try app.credentials.keyCredential(for: key) else {
            throw TermindSSHError.library(
                String(localized: AppStrings.Keychain.thePrivateKeyIsUnavailableOnThisMac)
            )
        }
        return secret.privateKey
    }

    private func delete(_ key: SSHKeyRef) throws {
        try app.credentials.delete(keyID: key.id)
        window.pruneVaultSelections(in: app.credentials)
    }

    private func saveSoftwareKey(
        _ original: SSHKeyRef, name: String, colorTag: TagColor, storage: KeyStorage,
        privateKey: String, passphrase: String?, certificate: String,
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

    private func saveSoftwareKeyMetadata(
        _ original: SSHKeyRef, name: String, colorTag: TagColor, certificate: String
    ) throws -> SSHKeyRef {
        var updated = original
        updated.label = name
        updated.colorTag = colorTag
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
                    LabeledContent(AppStrings.Keychain.storeIn.swiftUIKey, value: key.storage.displayName)
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
        VaultDetailScaffold(title: AppStrings.Keychain.exportToHosts, symbol: "square.and.arrow.up", close: close) {
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
                    Text(AppStrings.Keychain.exportToHosts)
                        .font(.headline)
                    Text(keySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Metrics.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    AppStrings.Vault.searchHosts.swiftUIKey, text: queryBinding.singleLineText, axis: .horizontal
                ).singleLinePaste()
                    .lineLimit(1)
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
                    .accessibilityLabel(Text(AppStrings.Common.clearSearch))
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
                Label(AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack")
            } description: {
                Text(AppStrings.Keychain.addAndConnectToAHostBeforeExportingAKeyToIt)
            }
        } else if hosts.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(hosts) { host in
                            row(for: host)
                                .frame(height: 52)
                                .id(host.id)
                        }
                    }
                }
                .onAppear { scrollCursorIntoView(using: proxy) }
                .onChange(of: chooser.cursor) { _, _ in scrollCursorIntoView(using: proxy) }
                .onChange(of: hosts.map(\.id)) { _, _ in scrollCursorIntoView(using: proxy) }
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
        }
    }

    private func scrollCursorIntoView(using proxy: ScrollViewProxy) {
        guard let cursor = chooser.cursor else { return }
        proxy.scrollTo(cursor)
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
            Label(AppStrings.Keychain.exported.swiftUIKey, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(AppStrings.Common.failed.swiftUIKey, systemImage: "exclamationmark.triangle.fill")
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
                        : String(
                            localized: AppStrings.Keychain.exportedFailed(
                                count1: states.count - failures, failures: failures))
                )
                .font(.caption)
                .foregroundStyle(
                    failures == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                )
                .monospacedDigit()
            } else {
                Text(AppStrings.Common.selected(chooser.selected.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button(
                    allEligibleChecked
                        ? AppStrings.Common.deselectAll.swiftUIKey : AppStrings.Common.selectAll.swiftUIKey
                ) {
                    toggleAllEligible()
                }
                .disabled(eligibleHosts.isEmpty || isExporting)
            }

            Spacer()

            Button(
                isFinished ? AppStrings.Common.done.swiftUIKey : AppStrings.Common.cancel.swiftUIKey, action: close
            )
            .keyboardShortcut(.cancelAction)
            .disabled(isExporting)

            if !isFinished {
                Button(AppStrings.Common.export.swiftUIKey, action: export)
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

    private var allEligibleChecked: Bool { chooser.allChecked(in: eligibleHosts.map(\.id)) }

    private var keySummary: String {
        if keys.count == 1 {
            return keys[0].label
        }
        return String(localized: AppStrings.Keychain.keysNamed(keys.count))
    }

    private func successSummary(hostCount: Int) -> String {
        if keys.count == 1 {
            return hostCount == 1
                ? String(localized: AppStrings.Keychain.exportedTo1Host)
                : String(localized: AppStrings.Keychain.exportedToHosts(hostCount))
        }
        return hostCount == 1
            ? String(localized: AppStrings.Keychain.exportedKeysTo1Host(keys.count))
            : String(localized: AppStrings.Keychain.exportedKeysToHosts(count: keys.count, hostCount: hostCount))
    }

    /// Select All follows the visible, filtered list, matching the host chooser:
    /// a filter must never cause an invisible machine to be modified.
    private func toggleAllEligible() {
        chooser.toggleAll(in: eligibleHosts.map(\.id))
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

        var preparations: [(Host.ID, SSHConnectionPreparation)] = []
        for host in targets {
            if let reason = app.credentials.keyExportUnavailableReason(for: host) {
                states[host.id] = .failed(reason)
                continue
            }
            do {
                preparations.append(
                    (host.id, try app.credentials.prepareSSHConnection(for: host))
                )
                states[host.id] = .running
            } catch {
                states[host.id] = .failed(error.localizedDescription)
            }
        }

        let exportKeys = keys.map {
            SSHAuthorizedKeyInstall(publicKey: $0.publicKey, name: $0.label)
        }
        let connectionCoordinator = app.connections
        Task {
            await withTaskGroup(of: (Host.ID, String?).self) { group in
                for (id, preparation) in preparations {
                    group.addTask {
                        do {
                            let configuration = try await preparation.resolve()
                            try await connectionCoordinator.installAuthorizedKeys(
                                exportKeys, using: configuration
                            )
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

/// The singular actions for one key, shared by its card and editor surfaces.
/// Card actions never resolve secret material; Edit is the explicit boundary
/// that loads a software key from Keychain.
struct KeyObjectActions: View {
    let key: SSHKeyRef
    let edit: () -> Void
    let export: () -> Void

    var body: some View {
        // Copy Fingerprint repeats Copy Public Key's verb, so the glyph stays on
        // the first of the pair.
        Button(AppStrings.Keychain.copyPublicKey.swiftUIKey, systemImage: MenuSymbol.copy) {
            copyToPasteboard(key.publicKey)
        }
        .disabled(key.publicKey.isEmpty)
        Button(AppStrings.KnownHosts.copyFingerprint.swiftUIKey) {
            copyToPasteboard(key.fingerprint)
        }
        Divider()
        Button(AppStrings.Keychain.exportToHosts.swiftUIKey, systemImage: MenuSymbol.export, action: export)
            .disabled(key.publicKey.isEmpty)
        Divider()
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
                            text: String(localized: AppStrings.Keychain.passphraseRequired),
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
            } else if actionIdentities.isEmpty {
                Button(AppStrings.Keychain.exportToHosts.swiftUIKey, systemImage: MenuSymbol.export, action: export)
                    .disabled(actionKeys.isEmpty || actionKeys.contains { $0.publicKey.isEmpty })
                Divider()
            }
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
