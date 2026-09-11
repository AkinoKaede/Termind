import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileHostEditor: View {
    let app: MobileAppModel
    private var library: HostLibraryModel { app.library }
    let original: Host
    @State private var draft: Host
    private let originalForwardings: [PortForwardingRule]
    @State private var draftForwardings: [PortForwardingRule]
    @State private var editingForwarding: PortForwardingRule?

    init(app: MobileAppModel, host: Host) {
        self.app = app
        let library = app.library
        original = host
        _draft = State(initialValue: host)
        originalForwardings = library.portForwardings(for: host.id)
        _draftForwardings = State(initialValue: library.portForwardings(for: host.id))
    }

    private var savedRules: [PortForwardingRule] {
        draftForwardings.filter { app.forwardingLibrary.portForwarding($0.id) == $0 }
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host"), isDirty: draft != original || draftForwardings != originalForwardings,
            canSave: !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (1...65535).contains(draft.port) && draftForwardings.allSatisfy(\.isValid),
            save: {
                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = draft.host }
                _ = library.upsert(draft, replacingPortForwardings: draftForwardings)
                if let error = library.storageError { throw MobileEditorError.message(error) }
            },
            content: {
                HostConnectionFields(host: $draft)
                Section("Authentication") {
                    Picker("Identity", selection: $draft.identityID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.identities) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Routing") {
                    Picker("Jump Host", selection: $draft.jumpHostID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.hosts.filter { $0.id != draft.id }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Port Forwarding") {
                    ForEach(draftForwardings) { rule in
                        HStack {
                            Button {
                                editingForwarding = rule
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(rule.label.isEmpty ? rule.bindAddress : rule.label)
                                    Text(app.forwardings.state(for: rule.id).label).font(.caption).foregroundStyle(
                                        .secondary)
                                }
                            }
                            Spacer()
                            Button(
                                app.forwardings.isEnabled(rule.id)
                                    ? String(localized: "Stop") : String(localized: "Start")
                            ) {
                                if app.forwardings.isEnabled(rule.id) {
                                    app.forwardings.stop(rule.id)
                                } else {
                                    app.forwardings.start(rule.id)
                                }
                            }.disabled(app.forwardingLibrary.portForwarding(rule.id) != rule)
                        }
                        .contextMenu {
                            Button("Duplicate") {
                                var copy = rule
                                copy.id = UUID()
                                draftForwardings.append(copy)
                            }
                            Button("Delete", role: .destructive) { draftForwardings.removeAll { $0.id == rule.id } }
                        }
                    }
                    Button("Add Port Forward", systemImage: "plus") {
                        editingForwarding = PortForwardingRule(hostID: draft.id)
                    }
                    HStack {
                        Spacer()
                        Button("Start All") { app.forwardings.start(savedRules.map(\.id)) }.disabled(savedRules.isEmpty)
                        Button("Stop All") { app.forwardings.stop(savedRules.map(\.id)) }.disabled(savedRules.isEmpty)
                    }
                    Text(
                        "Forwarding uses a background SSH connection and stops when Termind quits. Save changes before starting a rule."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Group") {
                    Picker("Group", selection: $draft.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
        )
        .sheet(item: $editingForwarding) { rule in
            MobileForwardingEditor(rule: rule) { updated in
                if let index = draftForwardings.firstIndex(where: { $0.id == updated.id }) {
                    draftForwardings[index] = updated
                } else {
                    draftForwardings.append(updated)
                }
            }
        }
    }
}

nonisolated enum MobileEditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
