import SwiftUI
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

@Observable
final class KnownHostsPageState {
    var query = ""
    var deleting: Set<UUID> = []
    var error: String?
}

struct KnownHostsPageView: ManagedCardPage {
    typealias SectionID = String
    typealias Item = KnownHostEntry
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession
    @Bindable var state: KnownHostsPageState

    var managedSections: [ManagedCardSection<String, KnownHostEntry>] {
        [
            ManagedCardSection(
                id: "knownHosts", title: String(localized: "Known Hosts"),
                items: app.knownHosts.search(state.query), canAcceptDrop: false, showsWhenEmpty: false)
        ]
    }
    var managedSelection: ManagedCardSelection<UUID> {
        ManagedCardSelection(
            selected: { Set(window.vaultSelection(for: .knownHosts).compactMap(\.knownHostID)) },
            update: { ids in
                window.setVaultSelection(
                    app.knownHosts.entries.filter { ids.contains($0.id) }.map { .knownHost($0.id) }, for: .knownHosts)
            }
        )
    }
    var managedCapabilities: ManagedCardCapabilities<String, UUID> { ManagedCardCapabilities() }
    var isManagedSourceEmpty: Bool { app.knownHosts.entries.isEmpty }
    func managedHeader(for section: ManagedCardSection<String, KnownHostEntry>, isDropTarget: Bool) -> some View {
        CardSectionHeader(title: section.title, count: section.items.count)
    }
    func managedCard(for item: KnownHostEntry, context: ManagedCardItemContext<KnownHostEntry>) -> some View {
        KnownHostCard(
            entry: item, selected: context.isSelected,
            select: { select(item, action: context.select) }, extend: context.extendSelection
        )
        .contextMenu {
            if context.actionItems.count == 1 {
                Button("Edit", systemImage: MenuSymbol.edit) {
                    window.openVaultWork(.knownHostEditor(item.id), on: .knownHosts)
                }
                Button("Copy Fingerprint", systemImage: MenuSymbol.copy) { copyToPasteboard(item.fingerprint) }
                Divider()
            }
            DestructiveMenuButton("Delete") {
                state.deleting = Set(context.actionItems.map(\.id))
            }
        }
        .onTapGesture(count: 2) { open(item, action: context.select) }
    }
    func managedGhost(for item: KnownHostEntry) -> some View {
        KnownHostCard(entry: item, selected: false, select: {}, extend: {})
    }
    func managedBlankAreaMenu(for section: String?) -> [NativeMenuEntry] {
        window.creationMenu(for: .knownHosts, locale: .current)
    }
    func managedBlankAreaPrimaryAction() {
        guard let route = window.vaultWorkRoute, case .knownHostEditor = route else { return }
        editingSession.requestTransition(route: route, action: window.closeVaultWork)
    }
    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("No Known Hosts", systemImage: "touchid")
        } description: {
            Text("Import trusted server keys or add a fingerprint manually.")
        } actions: {
            Button("Import Known Hosts") { window.openVaultWork(.sshImport(knownHostsOnly: true), on: .knownHosts) }
            Button("Add Host Key") { window.openVaultWork(.knownHostEditor(nil), on: .knownHosts) }
        }
    }
    func managedNoResultsState() -> some View { ContentUnavailableView.search(text: state.query) }
    var managedPresentation: ManagedCardDeletionPresentation<UUID> {
        ManagedCardDeletionPresentation(
            deleting: $state.deleting, error: $state.error, ids: app.knownHosts.entries.map(\.id),
            confirmationTitle: "Delete Host Keys?", errorTitle: "Known Hosts Operation Failed",
            explanation: Text("The next connection will ask you to verify the server key again."),
            prune: { window.pruneVaultSelections(in: app.hostLibrary) },
            delete: {
                if !app.knownHosts.delete(state.deleting) { state.error = app.knownHosts.storageError }
                state.deleting = []
                window.pruneVaultSelections(in: app.hostLibrary)
            })
    }

    private func select(_ entry: KnownHostEntry, action: @escaping () -> Void) {
        guard let route = window.vaultWorkRoute, case .knownHostEditor(let editingID) = route else {
            action()
            return
        }
        guard editingID != entry.id else {
            action()
            return
        }
        editingSession.requestTransition(route: route) {
            action()
            window.openVaultWork(.knownHostEditor(entry.id), on: .knownHosts)
        }
    }

    private func open(_ entry: KnownHostEntry, action: @escaping () -> Void) {
        if let route = window.vaultWorkRoute, case .knownHostEditor(let editingID) = route,
            editingID != entry.id
        {
            editingSession.requestTransition(route: route) {
                action()
                window.openVaultWork(.knownHostEditor(entry.id), on: .knownHosts)
            }
            return
        }
        action()
        window.openVaultWork(.knownHostEditor(entry.id), on: .knownHosts)
    }
}

private struct KnownHostCard: View {
    @Environment(\.locale) private var locale

    let entry: KnownHostEntry
    let selected: Bool
    let select: () -> Void
    let extend: () -> Void
    var body: some View {
        CardTile(
            selectionID: VaultSelectionID.knownHost(entry.id), isSelected: selected, select: select,
            extendSelection: extend
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack {
                    CardIcon(symbol: "touchid", tint: TermindColor.accent)
                    VStack(alignment: .leading) {
                        Text(entry.presentationTitle).font(.headline).lineLimit(1)
                        Text(entry.algorithm.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer(minLength: Metrics.Space.xs)
                    Text(entry.addedAt.formatted(.relative(presentation: .numeric).locale(locale)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .help(entry.displayAddress)
    }
}

struct KnownHostEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession
    let entryID: UUID?
    @State private var draft: KnownHostEntry
    @State private var original: KnownHostEntry
    @State private var loaded = false
    @State private var error: String?
    @State private var deletionError: String?
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?

    init(entryID: UUID?) {
        self.entryID = entryID
        let initial = KnownHostEntry(hostname: "")
        _draft = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    private var isDirty: Bool { draft != original }

    var body: some View {
        VaultDetailScaffold(
            title: entryID == nil ? "Add Host Key" : "Edit Host Key", symbol: "touchid",
            close: cancelEditing, closeLabel: "Cancel"
        ) {
            Form {
                Section("Host") {
                    TextField("Hostname", text: $draft.hostname.singleLineText, axis: .horizontal).singleLinePaste()
                        .lineLimit(1)
                    if !draft.isHashed {
                        TextField("Port", value: $draft.port, format: .number.grouping(.never)).lineLimit(1)
                    }
                    if draft.isHashed {
                        Text("The original address and port cannot be recovered from this hash.").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Host Key") {
                    Picker("Key Type", selection: $draft.algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Fingerprint", text: $draft.fingerprint.singleLineText, axis: .horizontal)
                        .singleLinePaste()
                        .lineLimit(1)
                        .font(.body.monospaced())
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        } footer: {
            HStack(spacing: Metrics.Space.m) {
                if entryID != nil {
                    Button("Delete", role: .destructive) { confirmsDeletion = true }
                }
                Spacer()
                Button("Cancel", action: cancelEditing)
                Button("Save", action: saveAndClose).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!draft.isValid)
            }.padding(Metrics.Space.l)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let entryID, let entry = app.knownHosts.entry(entryID) {
                draft = entry
                original = entry
            }
            editingToken = editingSession.register(
                route: .knownHostEditor(entryID), isDirty: { isDirty }
            ) { commitChanges() }
        }
        .onDisappear {
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog("Delete Host Keys?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will ask you to verify the server key again.")
        }
        .alert(
            "Known Hosts Operation Failed",
            isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })
        ) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    private func cancelEditing() {
        editingSession.requestTransition(route: .knownHostEditor(entryID), action: window.closeVaultWork)
    }

    private func commitChanges() -> Bool {
        guard isDirty else { return true }
        guard draft.isValid else {
            error = String(localized: "Complete all required fields before saving.")
            return false
        }
        guard app.knownHosts.save(draft) else {
            error = app.knownHosts.storageError ?? String(localized: "Unable to Save")
            return false
        }
        original = draft
        error = nil
        window.selectVaultItem(.knownHost(draft.id), on: .knownHosts)
        return true
    }

    private func saveAndClose() {
        guard commitChanges() else { return }
        window.selectVaultItem(.knownHost(draft.id), on: .knownHosts)
        window.closeVaultWork()
    }

    private func delete() {
        guard let entryID else { return }
        guard app.knownHosts.delete([entryID]) else {
            deletionError = app.knownHosts.storageError ?? String(localized: "Unable to Save")
            return
        }
        window.pruneVaultSelections(in: app.hostLibrary)
        window.closeVaultWork()
    }
}
