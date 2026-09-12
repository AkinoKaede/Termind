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
    let save: (PortForwardingRule) -> Void
    @State private var draft: PortForwardingRule

    init(
        app: MobileAppModel, host: Host, rule: PortForwardingRule,
        save: @escaping (PortForwardingRule) -> Void
    ) {
        self.app = app
        self.host = host
        original = rule
        self.save = save
        _draft = State(initialValue: rule)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Port Forwarding"), isDirty: draft != original,
            canSave: draft.isValid && state.canEdit,
            save: { save(draft) },
            content: {
                Section {
                    Toggle("Enabled", isOn: enabled)
                        .disabled(!state.canToggle)
                    LabeledContent("Status", value: runtime.label)
                    if !state.hasSavedConfiguration {
                        Text("Save the host and forwarding changes before starting this rule.")
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
            rule: draft, host: host,
            savedRule: app.forwardingLibrary.portForwarding(draft.id), savedHost: app.library.host(host.id),
            isEnabled: app.forwardings.isEnabled(draft.id), isRuntimeActive: runtime.isActive)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { state.isEnabled || state.isRuntimeActive },
            set: { value in
                guard !value || state.canStart else { return }
                app.forwardings.setEnabled(value, for: draft.id)
            })
    }
}
