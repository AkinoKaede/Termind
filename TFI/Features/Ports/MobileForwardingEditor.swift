import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

/// Rules belong to the host draft and commit in its one Vault transaction.
struct MobileForwardingEditor: View {
    let app: MobileAppModel
    let host: Host
    let original: PortForwardingRule
    let isNew: Bool
    let save: (PortForwardingRule) -> Void
    @State private var draft: PortForwardingRule

    init(
        app: MobileAppModel, host: Host, rule: PortForwardingRule, isNew: Bool,
        save: @escaping (PortForwardingRule) -> Void
    ) {
        self.app = app
        self.host = host
        original = rule
        self.isNew = isNew
        self.save = save
        _draft = State(initialValue: rule)
    }

    var body: some View {
        MobileEditorSheet(
            title: isNew ? String(localized: "New Forwarding") : String(localized: "Edit Forwarding"),
            isDirty: draft != original || (isNew && state.isEnabled),
            canSave: draft.isValid && state.canEdit,
            onCancel: cancel,
            save: { save(draft) },
            content: {
                Section {
                    Toggle("Enabled", isOn: enabled)
                        .disabled(!state.canToggle)
                    LabeledContent(
                        "Status",
                        value: state.isWaitingForSave ? String(localized: "Waiting for Save") : runtime.label
                    )
                    if state.isWaitingForSave {
                        Text("This forwarding will start after the host is saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                PortForwardingFields(rule: $draft)
                    .disabled(!state.canEdit)
            })
    }

    private var runtime: PortForwardingRuntimeState { app.forwardings.state(for: draft.id) }

    private var state: PortForwardingEditorPolicy {
        PortForwardingEditorPolicy(
            rule: draft,
            savedRule: app.forwardingLibrary.portForwarding(draft.id), savedHost: app.library.host(host.id),
            isEnabled: app.forwardings.isEnabled(draft.id), isRuntimeActive: runtime.isActive)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { state.isEnabled || state.isRuntimeActive },
            set: { value in
                app.forwardings.setEnabled(value, for: draft.id)
            })
    }

    private func cancel() {
        if isNew { app.forwardings.discardPending([draft.id]) }
    }
}
