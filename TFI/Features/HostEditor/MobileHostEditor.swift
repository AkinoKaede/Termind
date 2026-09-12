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

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host"), isDirty: draft != original || draftForwardings != originalForwardings,
            canSave: !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (1...65535).contains(draft.port) && draftForwardings.allSatisfy(\.isValid),
            onCancel: cancel,
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
                        let runtime = app.forwardings.state(for: rule.id)
                        let state = forwardingState(for: rule, runtimeIsActive: runtime.isActive)
                        let isRunning = state.isEnabled || state.isRuntimeActive
                        HStack {
                            Button {
                                editingForwarding = rule
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(rule.label.isEmpty ? rule.bindAddress : rule.label)
                                        Text(
                                            state.isWaitingForSave
                                                ? String(localized: "Waiting for Save") : runtime.label
                                        )
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "arrow.left.arrow.right").accessibilityHidden(true)
                                }
                            }
                            Spacer()
                            Button(
                                isRunning ? String(localized: "Disable") : String(localized: "Enable"),
                                systemImage: isRunning ? "stop" : "play"
                            ) {
                                app.forwardings.setEnabled(!isRunning, for: rule.id)
                            }.disabled(!state.canToggle)
                        }
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                var copy = rule
                                copy.id = UUID()
                                draftForwardings.append(copy)
                            }
                            .disabled(!state.canEdit)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                app.forwardings.discardPending([rule.id])
                                draftForwardings.removeAll { $0.id == rule.id }
                            }
                            .disabled(!state.canEdit)
                        }
                    }
                    Button("Add Forwarding", systemImage: "plus") {
                        editingForwarding = PortForwardingRule(hostID: draft.id)
                    }
                    Text(
                        "Enabled is saved immediately on this device. Unsaved forwarding changes apply after the host is saved."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Color") {
                    ColorTagPicker(selection: $draft.colorTag, layout: .touch)
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
            MobileForwardingEditor(
                app: app, host: draft, rule: rule,
                isNew: !draftForwardings.contains { $0.id == rule.id }
            ) { updated in
                if let index = draftForwardings.firstIndex(where: { $0.id == updated.id }) {
                    draftForwardings[index] = updated
                } else {
                    draftForwardings.append(updated)
                }
            }
        }
    }

    private func cancel() {
        app.forwardings.discardPending(draftForwardings.map(\.id))
    }

    private func forwardingState(
        for rule: PortForwardingRule, runtimeIsActive: Bool
    ) -> PortForwardingEditorPolicy {
        PortForwardingEditorPolicy(
            rule: rule,
            savedRule: app.forwardingLibrary.portForwarding(rule.id), savedHost: library.host(draft.id),
            isEnabled: app.forwardings.isEnabled(rule.id), isRuntimeActive: runtimeIsActive)
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
