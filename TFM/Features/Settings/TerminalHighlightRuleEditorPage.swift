import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

/// Uses the same settings-page navigation and immediate persistence as the skill editor.
struct TerminalHighlightRuleEditorPage: View {
    @State var rule: TerminalHighlightRule
    let model: TerminalHighlightSettingsModel
    let deleted: () -> Void
    @State private var wasDeleted = false

    var body: some View {
        SettingsFormPage {
            TerminalHighlightRuleFields(rule: $rule, model: model)
            if let error = model.failureMessage { Text(error).foregroundStyle(.red) }
            if model.preferences.rules.contains(where: { $0.id == rule.id }) {
                Section {
                    HStack {
                        Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                            if model.delete(rule.id) {
                                wasDeleted = true
                                deleted()
                            }
                        }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .task(id: rule) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            saveIfValid()
        }
        .onDisappear { saveIfValid() }
    }

    private func saveIfValid() {
        guard !wasDeleted, model.validationIssue(for: rule) == nil else { return }
        model.upsert(rule)
    }
}
