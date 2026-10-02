import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalHighlightSettingsView: View {
    private let model: TerminalHighlightSettingsModel
    @State private var editingRule: TerminalHighlightRule?

    init(model: TerminalHighlightSettingsModel) { self.model = model }

    var body: some View {
        Form {
            TerminalHighlightSettingsSection(model: model, showsTitle: false) { editingRule = $0 }
        }
        .formStyle(.grouped)
        .navigationTitle(AppStrings.TerminalHighlighting.title.swiftUIKey)
        .sheet(item: $editingRule) { rule in
            MobileTerminalHighlightRuleEditor(rule: rule, model: model)
        }
    }
}
