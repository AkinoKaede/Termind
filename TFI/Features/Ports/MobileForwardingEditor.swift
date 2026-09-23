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
            title: isNew
                ? String(localized: TermindCopy.Forwarding.newForwarding)
                : String(localized: TermindCopy.Forwarding.editForwarding),
            isDirty: draft != original, canSave: canSave,
            save: {
                guard canSave, let rule = PortForwardingEditorPolicy.normalized(draft) else { return }
                draft = try app.forwardingLibrary.save(rule)
            },
            content: {
                PortForwardingFields(rule: $draft, hosts: app.forwardingLibrary.hosts)
                    .disabled(app.forwardings.state(for: draft.id).isActive)
            })
    }
}
