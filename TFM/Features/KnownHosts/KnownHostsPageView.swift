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
            entry: item, selected: context.isSelected, select: context.select, extend: context.extendSelection
        )
        .contextMenu {
            if context.actionItems.count == 1 {
                Button("Edit", systemImage: MenuSymbol.edit) {
                    window.openVaultWork(.knownHostEditor(item.id), on: .knownHosts)
                }
                Button("Copy Fingerprint", systemImage: MenuSymbol.copy) { copyToPasteboard(item.fingerprint) }
                Divider()
            }
            Button("Delete", systemImage: MenuSymbol.delete, role: .destructive) {
                state.deleting = Set(context.actionItems.map(\.id))
            }
        }
        .onTapGesture(count: 2) { window.openVaultWork(.knownHostEditor(item.id), on: .knownHosts) }
    }
    func managedGhost(for item: KnownHostEntry) -> some View {
        KnownHostCard(entry: item, selected: false, select: {}, extend: {})
    }
    func managedBlankAreaMenu(for section: String?) -> [NativeMenuEntry] {
        window.creationMenu(for: .knownHosts, locale: .current)
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
    let entryID: UUID?
    @State private var draft = KnownHostEntry(hostname: "")
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        VaultDetailScaffold(title: "Host Key", symbol: "touchid", close: window.closeVaultWork) {
            Form {
                TextField("Hostname", text: $draft.hostname.singleLineText, axis: .horizontal).singleLinePaste()
                    .lineLimit(1)
                if !draft.isHashed {
                    TextField("Port", value: $draft.port, format: .number.grouping(.never)).lineLimit(1)
                }
                Picker("Key Type", selection: $draft.algorithm) {
                    ForEach(SSHKeyAlgorithm.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Fingerprint", text: $draft.fingerprint.singleLineText, axis: .horizontal).singleLinePaste()
                    .lineLimit(1)
                    .font(.body.monospaced())
                if draft.isHashed {
                    Text("The original address and port cannot be recovered from this hash.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: window.closeVaultWork)
                Button("Save") {
                    if app.knownHosts.save(draft) {
                        window.selectVaultItem(.knownHost(draft.id), on: .knownHosts)
                        window.closeVaultWork()
                    } else {
                        error = app.knownHosts.storageError
                    }
                }.disabled(!draft.isValid)
            }.padding()
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let entryID, let entry = app.knownHosts.entry(entryID) { draft = entry }
        }
    }
}
