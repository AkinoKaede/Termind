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
            TerminalHighlightRuleFields(rule: $rule)
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
            if model.preferences.rules.contains(where: { $0.id == rule.id }) {
                Section {
                    HStack {
                        Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                            var next = model.preferences
                            next.rules.removeAll { $0.id == rule.id }
                            if model.save(next) {
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
        guard !wasDeleted else { return }
        model.upsert(rule, validate: { TerminalKeywordHighlighting.validationIssue($0) == nil })
    }
}
