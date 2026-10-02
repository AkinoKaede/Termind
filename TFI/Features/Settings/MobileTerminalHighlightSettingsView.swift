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
            TerminalHighlightSettingsSection(model: model, showsTitle: false, showsAddRule: false) { editingRule = $0 }
        }
        .formStyle(.grouped)
        .navigationTitle(AppStrings.TerminalHighlighting.title.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(AppStrings.TerminalHighlighting.addRule.swiftUIKey, systemImage: "plus") {
                    editingRule = TerminalHighlightRule()
                }
                .labelStyle(.iconOnly)
                .disabled(!model.canAddRule)
            }
        }
        .sheet(item: $editingRule) { rule in
            MobileTerminalHighlightRuleEditor(rule: rule, model: model)
        }
    }
}
