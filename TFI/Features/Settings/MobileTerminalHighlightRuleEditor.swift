import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalHighlightRuleEditor: View {
    @State private var rule: TerminalHighlightRule
    private let original: TerminalHighlightRule
    private let model: TerminalHighlightSettingsModel
    @Environment(\.dismiss) private var dismiss

    init(rule: TerminalHighlightRule, model: TerminalHighlightSettingsModel) {
        _rule = State(initialValue: rule)
        original = rule
        self.model = model
    }

    private var isNew: Bool { !model.preferences.rules.contains { $0.id == rule.id } }
    private var canSave: Bool {
        model.validationIssue(for: rule) == nil
    }

    var body: some View {
        MobileEditorSheet(
            title: String(
                localized: isNew ? AppStrings.TerminalHighlighting.addRule : AppStrings.TerminalHighlighting.editRule),
            isDirty: rule != original, canSave: canSave,
            actions: toolbarActions,
            discardQuestion: isNew
                ? AppStrings.Common.discardNewHighlightRuleQuestion : AppStrings.Common.discardChangesQuestion,
            save: {
                guard model.upsert(rule) else {
                    throw MobileEditorError.message(
                        model.failureMessage ?? String(localized: AppStrings.TerminalHighlighting.invalidPattern))
                }
            },
            content: {
                TerminalHighlightRuleFields(rule: $rule, model: model)
                if let error = model.failureMessage { Section { Text(error).foregroundStyle(.red) } }
            }
        )
    }

    private var toolbarActions: [MobileEditorToolbarAction] {
        guard !isNew, !rule.isBuiltIn else { return [] }
        return [
            MobileEditorToolbarAction(
                id: "delete", title: AppStrings.Common.delete, systemImage: "trash", role: .destructive,
                perform: {
                    if model.delete(rule.id) { dismiss() }
                })
        ]
    }
}
