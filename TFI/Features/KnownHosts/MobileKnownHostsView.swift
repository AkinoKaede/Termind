import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

struct MobileKnownHostsView: View {
    @Environment(\.locale) private var locale

    let app: MobileAppModel
    @State private var editing: KnownHostEntry?
    @State private var removing: KnownHostEntry?
    @State private var query = ""

    private var entries: [KnownHostEntry] { app.knownHosts.search(query) }

    init(app: MobileAppModel, initialQuery: String = "") {
        self.app = app
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        MobileCardPage {
            if app.knownHosts.entries.isEmpty {
                ContentUnavailableView(TermindCopy.KnownHosts.noKnownHosts.swiftUIKey, systemImage: "checkmark.shield")
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            MobileCardGrid {
                ForEach(entries) { entry in
                    MobileActionCard {
                        editing = entry
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                MobileCardIcon(symbol: "touchid", tint: .accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.presentationTitle).font(.headline).lineLimit(1)
                                    Text(entry.algorithm.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack(spacing: 6) {
                                Spacer(minLength: 6)
                                Text(entry.addedAt.formatted(.relative(presentation: .numeric).locale(locale)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } actions: {
                        Button(TermindCopy.Common.edit.swiftUIKey, systemImage: "pencil") { editing = entry }
                        Button(TermindCopy.KnownHosts.copyFingerprint.swiftUIKey, systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = entry.fingerprint
                        }
                        Divider()
                        Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            removing = entry
                        }
                    }
                }
            }
        }
        .searchable(text: $query.singleLineText)
        .navigationTitle(TermindCopy.Navigation.knownHosts.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(TermindCopy.KnownHosts.addKnownHost.swiftUIKey, systemImage: "plus") {
                    editing = KnownHostEntry(hostname: "")
                }
            }
        }
        .sheet(item: $editing) { entry in
            MobileKnownHostEditor(app: app, entry: entry, isNew: app.knownHosts.entry(entry.id) == nil)
        }
        .confirmationDialog(
            TermindCopy.KnownHosts.deleteKnownHostConfirmation.swiftUIKey,
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button(TermindCopy.Common.delete.swiftUIKey, role: .destructive) {
                if let entry = removing { _ = app.knownHosts.delete([entry.id]) }
                removing = nil
            }
        }
    }
}

struct MobileKnownHostEditor: View {
    let app: MobileAppModel
    let original: KnownHostEntry
    let isNew: Bool
    @State private var draft: KnownHostEntry

    init(app: MobileAppModel, entry: KnownHostEntry, isNew: Bool? = nil) {
        self.app = app
        original = entry
        self.isNew = isNew ?? (app.knownHosts.entry(entry.id) == nil)
        _draft = State(initialValue: entry)
    }

    var editorTitle: String {
        isNew
            ? String(localized: TermindCopy.KnownHosts.addKnownHost)
            : String(localized: TermindCopy.KnownHosts.editKnownHost)
    }

    var body: some View {
        MobileEditorSheet(
            title: editorTitle, isDirty: draft != original,
            canSave: draft.isValid,
            save: {
                guard app.knownHosts.save(draft) else {
                    throw MobileEditorError.message(
                        app.knownHosts.storageError ?? String(localized: TermindCopy.Common.unableToSave))
                }
            },
            content: {
                Section(TermindCopy.Vault.host.swiftUIKey) {
                    LabeledContent(TermindCopy.Vault.hostname.swiftUIKey) {
                        TextField(
                            TermindCopy.Vault.hostname.swiftUIKey, text: $draft.hostname.singleLineText,
                            axis: .horizontal
                        ).singleLinePaste()
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if !draft.isHashed {
                        LabeledContent(TermindCopy.Common.port.swiftUIKey) {
                            TextField(
                                TermindCopy.Common.port.swiftUIKey, value: $draft.port, format: .number.grouping(.never)
                            ).lineLimit(1)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                    }
                    if draft.isHashed {
                        Text(TermindCopy.KnownHosts.hashedAddressExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(TermindCopy.KnownHosts.hostKey.swiftUIKey) {
                    Picker(TermindCopy.KnownHosts.keyType.swiftUIKey, selection: $draft.algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent(TermindCopy.KnownHosts.fingerprint.swiftUIKey) {
                        TextField(
                            TermindCopy.KnownHosts.fingerprint.swiftUIKey, text: $draft.fingerprint.singleLineText,
                            axis: .horizontal
                        ).lineLimit(
                            1
                        )
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
            })
    }
}
