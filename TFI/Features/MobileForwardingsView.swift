import SwiftUI
import TermindDomain
import TermindPresentation

struct MobileForwardingsView: View {
    let app: MobileAppModel
    @State private var editing: PortForwardingRule?
    @State private var removing: PortForwardingRule?
    @State private var error: String?

    var body: some View {
        List(app.forwardingLibrary.rules) { rule in
            VStack(alignment: .leading, spacing: 8) {
                Text(rule.label.isEmpty ? rule.bindAddress : rule.label).font(.headline)
                Text(app.library.host(rule.hostID)?.name ?? "").font(.caption)
                Text(app.forwardings.state(for: rule.id).label).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(app.forwardings.isEnabled(rule.id) ? String(localized: "Stop") : String(localized: "Start"))
                    {
                        if app.forwardings.isEnabled(rule.id) {
                            app.forwardings.stop(rule.id)
                        } else {
                            app.forwardings.start(rule.id)
                        }
                    }
                    Button("Edit") { editing = rule }
                }.buttonStyle(.bordered)
            }
            .swipeActions { Button("Delete", role: .destructive) { removing = rule } }
        }
        .navigationTitle("Port Forwarding")
        .toolbar {
            Button("Add", systemImage: "plus") {
                if let host = app.library.hosts.first { editing = PortForwardingRule(hostID: host.id) }
            }.disabled(app.library.hosts.isEmpty)
        }
        .sheet(item: $editing) { MobileForwardingEditor(app: app, rule: $0) }
        .confirmationDialog(
            "Delete Forwarding Rule?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let rule = removing {
                    do { try app.forwardingLibrary.delete(rule.id) } catch { self.error = error.localizedDescription }
                }
                removing = nil
            }
        }
        .alert("Unable to Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

private struct MobileForwardingEditor: View {
    let app: MobileAppModel
    let original: PortForwardingRule
    @State private var draft: PortForwardingRule

    init(app: MobileAppModel, rule: PortForwardingRule) {
        self.app = app
        original = rule
        _draft = State(initialValue: rule)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Port Forwarding"), isDirty: draft != original,
            canSave: draft.isValid, save: { try app.forwardingLibrary.save(draft) },
            content: {
                Picker("Host", selection: $draft.hostID) {
                    ForEach(app.library.hosts) { Text($0.name).tag($0.id) }
                }.disabled(app.forwardingLibrary.portForwarding(original.id) != nil)
                PortForwardingFields(rule: $draft)
            })
    }
}
