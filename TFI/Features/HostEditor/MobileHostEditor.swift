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
            canSave: MobileHostEditorPolicy.canSave(draft, forwardings: draftForwardings),
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
                    Picker("Proxy", selection: proxyKind) {
                        Text("None").tag(HostProxy.ProtocolKind?.none)
                        ForEach(HostProxy.ProtocolKind.allCases) { kind in
                            Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                        }
                    }
                    if draft.proxy != nil {
                        LabeledContent("Hostname") {
                            TextField("Hostname", text: proxyString(\.hostname))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityLabel("Proxy Hostname")
                        LabeledContent("Port") {
                            TextField("Port", value: proxyInt(\.port), format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityLabel("Proxy Port")
                        Picker("Identity", selection: proxyIdentityID) {
                            Text("None").tag(UUID?.none)
                            ForEach(proxyIdentities) { identity in
                                Text("\(identity.name) · \(identity.username)").tag(Optional(identity.id))
                            }
                        }
                        .accessibilityLabel("Proxy Identity")
                        if draft.proxy?.identityID != nil {
                            LabeledContent("Username") {
                                TextField("Username", text: proxyString(\.username))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                            }
                            .accessibilityLabel("Proxy Username")
                        }
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

    private var proxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.proxy?.kind
        } set: { kind in
            draft.proxy = MobileHostEditorPolicy.selectProxy(kind, current: draft.proxy)
        }
    }

    private func proxyString(_ keyPath: WritableKeyPath<HostProxy, String>) -> Binding<String> {
        Binding(
            get: { draft.proxy?[keyPath: keyPath] ?? "" },
            set: { draft.proxy?[keyPath: keyPath] = $0 }
        )
    }

    private func proxyInt(_ keyPath: WritableKeyPath<HostProxy, Int>) -> Binding<Int> {
        Binding(
            get: { draft.proxy?[keyPath: keyPath] ?? 0 },
            set: { draft.proxy?[keyPath: keyPath] = $0 }
        )
    }

    private var proxyIdentityID: Binding<Identity.ID?> {
        Binding {
            draft.proxy?.identityID
        } set: { identityID in
            draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(
                identityID.flatMap(library.identity), current: draft.proxy)
        }
    }

    private var proxyIdentities: [Identity] {
        library.identities.filter(library.isProxyEligibleOnThisDevice)
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

nonisolated enum MobileHostEditorPolicy {
    static func canSave(_ host: Host, forwardings: [PortForwardingRule]) -> Bool {
        !host.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(host.port)
            && (host.proxy?.isValid ?? true)
            && forwardings.allSatisfy(\.isValid)
    }

    static func selectProxy(
        _ kind: HostProxy.ProtocolKind?, current: HostProxy?
    ) -> HostProxy? {
        guard let kind else { return nil }
        guard var proxy = current else {
            return HostProxy(kind: kind, port: kind.defaultPort)
        }
        if proxy.kind != kind {
            let oldDefaultPort = proxy.kind.defaultPort
            proxy.kind = kind
            if proxy.port == oldDefaultPort { proxy.port = kind.defaultPort }
        }
        return proxy
    }

    static func selectProxyIdentity(_ identity: Identity?, current: HostProxy?) -> HostProxy? {
        guard var proxy = current else { return nil }
        proxy.identityID = identity?.id
        proxy.username = identity?.username ?? ""
        return proxy
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
