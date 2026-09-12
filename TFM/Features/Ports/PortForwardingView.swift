import SwiftUI
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

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
                    edit: { openEditor(rule) },
                    duplicate: { duplicate(rule) },
                    delete: { rules.removeAll { $0.id == rule.id } }
                )
            }
            FormNavigationAction(title: "Add Forwarding") {
                openEditor(PortForwardingRule(hostID: host.id))
            }
            if !rules.isEmpty {
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
                .disabled(startableRules.isEmpty)
            Button("Stop All", action: stopAll)
                .disabled(runningRules.isEmpty)
        }
    }

    private var startableRules: [PortForwardingRule] {
        rules.filter {
            PortForwardingEditorState(
                ruleID: $0.id, rule: PortForwardingEditorState.normalized($0), host: host, app: app
            ).canStart
        }
    }

    private var runningRules: [PortForwardingRule] {
        rules.filter { app.forwarding.isEnabled($0.id) || app.forwarding.state(for: $0.id).isActive }
    }

    private func duplicate(_ rule: PortForwardingRule) {
        var copy = rule
        copy.id = UUID()
        if !copy.label.isEmpty { copy.label += String(localized: " Copy") }
        rules.append(copy)
    }

    private func startAll() {
        app.forwarding.setEnabled(true, for: startableRules.map(\.id))
    }

    private func stopAll() {
        app.forwarding.setEnabled(false, for: runningRules.map(\.id))
    }
}

private struct HostForwardingRow: View {
    let host: Host
    let rule: PortForwardingRule
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    private var state: PortForwardingEditorState {
        PortForwardingEditorState(
            ruleID: rule.id, rule: PortForwardingEditorState.normalized(rule), host: host, app: app)
    }
    private var runtime: PortForwardingRuntimeState { state.runtime }
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
                .disabled(!state.canToggle)
                .accessibilityLabel(Text("Enable \(title)"))
            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit \(title)"))
        }
        .contentShape(.rect)
        .onTapGesture(perform: edit)
        .contextMenu {
            HostForwardingContextMenu(
                host: host, rule: rule,
                edit: edit, duplicate: duplicate, delete: delete
            )
        }
        .help(Text(rule.summary))
    }

    @ViewBuilder
    private var statusChip: some View {
        if state.hasSavedConfiguration || !state.canEdit {
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
            get: { state.isEnabled || state.runtime.isActive },
            set: { value in
                if value {
                    guard state.canStart else { return }
                    app.forwarding.setEnabled(true, for: rule.id)
                } else {
                    app.forwarding.setEnabled(false, for: rule.id)
                }
            }
        )
    }
}

private struct HostForwardingContextMenu: View {
    let host: Host
    let rule: PortForwardingRule
    let edit: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @Environment(AppModel.self) private var app

    private var state: PortForwardingEditorState {
        PortForwardingEditorState(
            ruleID: rule.id, rule: PortForwardingEditorState.normalized(rule), host: host, app: app)
    }
    private var isActive: Bool { !state.canEdit }
    private var command: String? { app.forwardings.sshCommand(for: rule, host: host) }

    var body: some View {
        let isRunning = state.isEnabled || state.runtime.isActive
        Button(
            isRunning ? String(localized: "Stop") : String(localized: "Start"),
            systemImage: isRunning ? MenuSymbol.stop : MenuSymbol.start,
            action: toggle
        )
        .disabled(!state.canToggle)
        Button("Edit", systemImage: MenuSymbol.edit, action: edit)
        Button("Duplicate", systemImage: MenuSymbol.duplicate, action: duplicate)
            .disabled(isActive)
        // Copy SSH Command repeats the verb above it, so only the first carries
        // the glyph.
        Button("Copy Address", systemImage: MenuSymbol.copy, action: copyAddress)
            .disabled(isActive)
        Button("Copy SSH Command", action: copyCommand)
            .disabled(isActive || command == nil)
        Divider()
        DestructiveMenuButton("Delete", action: delete).disabled(isActive)
    }

    private func toggle() {
        if state.isEnabled || state.runtime.isActive {
            app.forwarding.setEnabled(false, for: rule.id)
        } else if state.canStart {
            app.forwarding.setEnabled(true, for: rule.id)
        }
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
    }

    var body: some View {
        VaultDetailScaffold(
            title: isNew ? "New Forwarding" : "Edit Forwarding",
            symbol: "arrow.left.arrow.right", close: back,
            closeLabel: "Back", closeSymbol: "chevron.backward"
        ) {
            Form {
                Section {
                    Toggle("Enabled", isOn: enabled)
                        .disabled(!state.canToggle)
                    LabeledContent("Status", value: state.runtime.label)
                    if !state.hasSavedConfiguration {
                        Text("Save the host and forwarding changes before starting this rule.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                PortForwardingFields(rule: $draft)
                    .disabled(!state.canEdit)
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        guard state.canEdit else { return }
                        delete()
                        back()
                    }
                    .disabled(!state.canEdit)
                }
                Spacer()
                Button("Cancel", action: back).keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedDraft == nil || !state.canEdit)
            }
            .padding(Metrics.Space.l)
        }
    }

    private var normalizedDraft: PortForwardingRule? {
        PortForwardingEditorState.normalized(draft)
    }

    private var state: PortForwardingEditorState {
        PortForwardingEditorState(ruleID: draft.id, rule: normalizedDraft, host: host, app: app)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { state.isEnabled || state.runtime.isActive },
            set: { value in
                if value {
                    guard state.canStart else { return }
                    app.forwarding.setEnabled(true, for: draft.id)
                } else {
                    app.forwarding.setEnabled(false, for: draft.id)
                }
            })
    }

    private func commit() {
        guard state.canEdit, let value = normalizedDraft else { return }
        save(value)
        back()
    }
}
