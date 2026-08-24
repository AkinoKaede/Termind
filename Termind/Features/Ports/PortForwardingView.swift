import SwiftUI

/// Host-scoped forwarding management embedded in `HostEditorView`.
struct PortForwardingEditorSection: View {
    let host: Host
    @Binding var rules: [PortForwardingRule]
    let openEditor: (PortForwardingRule) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        forwardingSection
    }

    private var forwardingSection: some View {
        Section("Port Forwarding") {
            ForEach(rules) { rule in
                HostForwardingRow(
                    host: host,
                    rule: rule,
                    canToggle: app.hosts.portForwarding(rule.id) == rule,
                    edit: { openEditor(rule) },
                    duplicate: { duplicate(rule) },
                    delete: { rules.removeAll { $0.id == rule.id } }
                )
            }
            FormNavigationAction(title: "Add Port Forward") {
                openEditor(PortForwardingRule(hostID: host.id))
            }
            if !savedRules.isEmpty {
                forwardingActions
            }
            Text(
                "Forwarding uses a background SSH connection and stops when Termind quits. Save changes before starting a rule."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var forwardingActions: some View {
        HStack(spacing: Metrics.Space.m) {
            Spacer()
            Button("Start All", action: startAll)
                .disabled(savedRules.allSatisfy { app.forwarding.isEnabled($0.id) })
            Button("Stop All", action: stopAll)
                .disabled(savedRules.allSatisfy { !app.forwarding.isEnabled($0.id) })
        }
    }

    private var savedRules: [PortForwardingRule] {
        rules.filter { app.hosts.portForwarding($0.id) == $0 }
    }

    private func duplicate(_ rule: PortForwardingRule) {
        var copy = rule
        copy.id = UUID()
        if !copy.label.isEmpty { copy.label += String(localized: " Copy") }
        rules.append(copy)
    }

    private func startAll() {
        app.forwarding.start(savedRules.filter { !app.forwarding.isEnabled($0.id) }.map(\.id))
    }

    private func stopAll() {
        app.forwarding.stop(savedRules.filter { app.forwarding.isEnabled($0.id) }.map(\.id))
    }
}

private struct HostForwardingRow: View {
    let host: Host
    let rule: PortForwardingRule
    let canToggle: Bool
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    private var runtime: PortForwardingRuntimeState { app.forwarding.state(for: rule.id) }
    private var title: String { rule.label.isEmpty ? rule.kind.displayName : rule.label }

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            Image(systemName: rule.kind.symbol)
                .foregroundStyle(runtime.isActive ? Color.green : Color.secondary)
                .frame(width: Metrics.Sidebar.rowIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(rule.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Metrics.Space.m)
            statusChip
            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!canToggle)
                .accessibilityLabel(Text("Enable \(title)"))
            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(runtime.isActive)
            .accessibilityLabel(Text("Edit \(title)"))
        }
        .contentShape(.rect)
        .onTapGesture { if !runtime.isActive { edit() } }
        .contextMenu {
            HostForwardingContextMenu(
                host: host, rule: rule, canToggle: canToggle,
                edit: edit, duplicate: duplicate, delete: delete
            )
        }
        .help(Text(rule.summary))
    }

    @ViewBuilder
    private var statusChip: some View {
        if canToggle {
            CardChip(
                text: runtime.label,
                symbol: runtime.isActive ? "circle.fill" : "circle",
                tint: runtime.isActive ? Color.green : nil
            )
        } else {
            CardChip(text: String(localized: "Save required"), symbol: "circle")
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { app.forwarding.isEnabled(rule.id) },
            set: { value in
                value ? app.forwarding.start(rule.id) : app.forwarding.stop(rule.id)
            }
        )
    }
}

private struct HostForwardingContextMenu: View {
    let host: Host
    let rule: PortForwardingRule
    let canToggle: Bool
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    private var isActive: Bool { app.forwarding.state(for: rule.id).isActive }
    private var command: String? { app.hosts.sshCommand(for: rule, host: host) }

    var body: some View {
        Button(app.forwarding.isEnabled(rule.id) ? "Stop" : "Start", action: toggle)
            .disabled(!canToggle)
        Button("Edit", action: edit).disabled(isActive)
        Button("Duplicate", action: duplicate).disabled(isActive)
        Button("Copy Address", action: copyAddress).disabled(isActive)
        Button("Copy SSH Command", action: copyCommand)
            .disabled(isActive || command == nil)
        Divider()
        Button("Delete", role: .destructive, action: delete).disabled(isActive)
    }

    private func toggle() {
        app.forwarding.isEnabled(rule.id)
            ? app.forwarding.stop(rule.id) : app.forwarding.start(rule.id)
    }

    private func copyAddress() { copyToPasteboard(rule.bindAddress) }
    private func copyCommand() { if let command { copyToPasteboard(command) } }
}

struct PortForwardingEditorSheet: View {
    let host: Host
    let isNew: Bool
    let back: () -> Void
    let delete: () -> Void
    let save: (PortForwardingRule) -> Void

    @Environment(AppModel.self) private var app
    @State private var draft: PortForwardingRule
    @State private var bindPortDraft: String
    @State private var targetHostDraft: String
    @State private var targetPortDraft: String
    @State private var showsAdvanced = false

    init(
        forwarding: PortForwardingRule, host: Host, isNew: Bool,
        back: @escaping () -> Void,
        delete: @escaping () -> Void,
        save: @escaping (PortForwardingRule) -> Void
    ) {
        self.host = host
        self.isNew = isNew
        self.back = back
        self.delete = delete
        self.save = save
        _draft = State(initialValue: forwarding)
        _bindPortDraft = State(initialValue: isNew ? "" : String(forwarding.bindPort))
        _targetHostDraft = State(initialValue: isNew ? "" : (forwarding.targetHost ?? ""))
        _targetPortDraft = State(
            initialValue: isNew ? "" : forwarding.targetPort.map(String.init) ?? ""
        )
    }

    var body: some View {
        VaultDetailScaffold(
            title: isNew ? "New Port Forward" : "Edit Port Forward",
            symbol: "arrow.left.arrow.right", close: back,
            closeLabel: "Back", closeSymbol: "chevron.backward"
        ) {
            Form {
                Section {
                    Picker("Direction", selection: $draft.kind) {
                        Text("Local").tag(PortForwardingRule.Kind.local)
                            .accessibilityLabel("Local Forward")
                        Text("Remote").tag(PortForwardingRule.Kind.remote)
                            .accessibilityLabel("Remote Forward")
                        Text("Dynamic").tag(PortForwardingRule.Kind.dynamic)
                            .accessibilityLabel("Dynamic SOCKS5 Proxy")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    Text(directionHelp).font(.caption).foregroundStyle(.secondary)
                }
                Section("SSH Host") {
                    LabeledContent("Host", value: host.name.isEmpty ? host.host : host.name)
                    if !host.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(app.hosts.routeSummary(for: host))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Forward") {
                    TextField("Name", text: $draft.label, prompt: Text("Optional"))
                    TextField(bindPortLabel, text: $bindPortDraft)
                    if draft.kind != .dynamic {
                        TextField(targetHostLabel, text: $targetHostDraft)
                        TextField("Destination Port", text: $targetPortDraft)
                    }
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        TextField(bindAddressLabel, text: $draft.bindHost)
                        if exposesNetwork {
                            Label(
                                "This address may expose the listener to other devices.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                Section("Route Preview") {
                    Text(routePreview).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        delete()
                        back()
                    }
                }
                Spacer()
                Button("Cancel", action: back).keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(Metrics.Space.l)
        }
    }

    private var directionHelp: String {
        switch draft.kind {
        case .local: String(localized: "This Mac → SSH Host → Target")
        case .remote: String(localized: "SSH Host → This Mac → Target")
        case .dynamic: String(localized: "SOCKS5 on This Mac → SSH Host → Requested Target")
        }
    }

    private var bindPortLabel: String {
        draft.kind == .dynamic ? "SOCKS Listen Port" : "Listen Port"
    }

    private var bindAddressLabel: String {
        switch draft.kind {
        case .local: "Listen Address on This Mac"
        case .remote: "Listen Address on SSH Host"
        case .dynamic: "SOCKS Listen Address on This Mac"
        }
    }

    private var targetHostLabel: String {
        draft.kind == .remote ? "Destination Host on This Mac" : "Destination Host from SSH Host"
    }

    private var exposesNetwork: Bool {
        !["127.0.0.1", "::1", "localhost"].contains(draft.bindHost.lowercased())
    }

    private var isValid: Bool {
        guard let bindPort = parsedBindPort else { return false }
        var value = draft
        value.bindPort = bindPort
        value.targetHost = draft.kind == .dynamic ? nil : targetHostDraft
        value.targetPort = draft.kind == .dynamic ? nil : parsedTargetPort
        return value.isValid
    }

    private var parsedBindPort: Int? {
        Int(bindPortDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var parsedTargetPort: Int? {
        Int(targetPortDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var routePreview: String {
        let start = previewAddress(draft.bindHost, port: parsedBindPort)
        let ssh = host.host.isEmpty ? String(localized: "SSH Host") : app.hosts.routeSummary(for: host)
        let targetHost = targetHostDraft.isEmpty ? "—" : targetHostDraft
        let targetPort = parsedTargetPort.map(String.init) ?? "—"
        switch draft.kind {
        case .local: return "\(start) → \(ssh) → \(targetHost):\(targetPort)"
        case .remote:
            return "\(ssh) → listen \(start) → This Mac → \(targetHost):\(targetPort)"
        case .dynamic: return "SOCKS5 \(start) → \(ssh) → Requested Target"
        }
    }

    private func previewAddress(_ host: String, port: Int?) -> String {
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return "\(formattedHost):\(port.map(String.init) ?? "—")"
    }

    private func commit() {
        guard let bindPort = parsedBindPort else { return }
        draft.hostID = host.id
        draft.bindHost = draft.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.bindPort = bindPort
        draft.targetHost =
            draft.kind == .dynamic
            ? nil : targetHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.targetPort = draft.kind == .dynamic ? nil : parsedTargetPort
        save(draft)
        back()
    }
}
