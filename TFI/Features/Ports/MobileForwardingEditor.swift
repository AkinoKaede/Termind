import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileForwardingEditor: View {
    let app: MobileAppModel
    let original: PortForwardingRule
    let isNew: Bool
    @State private var draft: PortForwardingRule

    init(app: MobileAppModel, rule: PortForwardingRule, isNew: Bool) {
        self.app = app
        original = rule
        self.isNew = isNew
        _draft = State(initialValue: rule)
    }

    private var canSave: Bool {
        PortForwardingEditorPolicy.normalized(draft) != nil && app.library.host(draft.hostID) != nil
            && !app.forwardings.state(for: draft.id).isActive
            && (isNew || app.forwardingLibrary.portForwarding(draft.id) != nil)
    }

    var body: some View {
        MobileEditorSheet(
            title: isNew ? String(localized: "New Forwarding") : String(localized: "Edit Forwarding"),
            isDirty: draft != original, canSave: canSave,
            save: {
                guard canSave, let rule = PortForwardingEditorPolicy.normalized(draft) else { return }
                try app.forwardingLibrary.save(rule)
            },
            content: {
                PortForwardingHostPicker(rule: $draft, hosts: app.forwardingLibrary.hosts)
                    .disabled(app.forwardings.state(for: draft.id).isActive)
                PortForwardingFields(rule: $draft).disabled(app.forwardings.state(for: draft.id).isActive)
            })
    }
}
