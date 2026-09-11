import SwiftUI
import TermindDomain
import TermindPresentation

/// Rules belong to the host draft and commit in its one Vault transaction.
struct MobileForwardingEditor: View {
    let original: PortForwardingRule
    let save: (PortForwardingRule) -> Void
    @State private var draft: PortForwardingRule

    init(rule: PortForwardingRule, save: @escaping (PortForwardingRule) -> Void) {
        original = rule
        self.save = save
        _draft = State(initialValue: rule)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Port Forwarding"), isDirty: draft != original,
            canSave: draft.isValid, save: { save(draft) }, content: { PortForwardingFields(rule: $draft) })
    }
}
