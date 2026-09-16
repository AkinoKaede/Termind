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
                ContentUnavailableView("No Known Hosts", systemImage: "checkmark.shield")
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
                        Button("Edit", systemImage: "pencil") { editing = entry }
                        Button("Copy Fingerprint", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = entry.fingerprint
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { removing = entry }
                    }
                }
            }
        }
        .searchable(text: $query.singleLineText)
        .navigationTitle("Known Hosts")
        .sheet(item: $editing) { MobileKnownHostEditor(app: app, entry: $0) }
        .confirmationDialog(
            "Delete Known Host?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = removing { _ = app.knownHosts.delete([entry.id]) }
                removing = nil
            }
        }
    }
}

struct MobileKnownHostEditor: View {
    let app: MobileAppModel
    let original: KnownHostEntry
    @State private var draft: KnownHostEntry

    init(app: MobileAppModel, entry: KnownHostEntry) {
        self.app = app
        original = entry
        _draft = State(initialValue: entry)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host Key"), isDirty: draft != original,
            canSave: draft.isValid,
            save: {
                guard app.knownHosts.save(draft) else {
                    throw MobileEditorError.message(
                        app.knownHosts.storageError ?? String(localized: "Unable to Save"))
                }
            },
            content: {
                Section {
                    LabeledContent("Hostname") {
                        TextField("Hostname", text: $draft.hostname.singleLineText, axis: .horizontal).singleLinePaste()
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if !draft.isHashed {
                        LabeledContent("Port") {
                            TextField("Port", value: $draft.port, format: .number.grouping(.never)).lineLimit(1)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                    }
                    Picker("Key Type", selection: $draft.algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Fingerprint") {
                        TextField("Fingerprint", text: $draft.fingerprint.singleLineText, axis: .horizontal).lineLimit(
                            1
                        )
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                if draft.isHashed {
                    Section {
                        Text("The original address and port cannot be recovered from this hash.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            })
    }
}
