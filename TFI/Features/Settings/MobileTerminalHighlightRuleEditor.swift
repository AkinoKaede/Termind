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
        !rule.isBuiltIn && rule.isValid && TerminalKeywordHighlighting.validationIssue(rule) == nil
    }

    var body: some View {
        MobileEditorSheet(
            title: String(
                localized: isNew ? AppStrings.TerminalHighlighting.addRule : AppStrings.TerminalHighlighting.editRule),
            isDirty: rule != original, canSave: canSave,
            actions: toolbarActions,
            save: {
                guard model.upsert(rule, validate: { TerminalKeywordHighlighting.validationIssue($0) == nil }) else {
                    throw MobileEditorError.message(
                        model.storageError ?? String(localized: AppStrings.TerminalHighlighting.invalidPattern))
                }
            },
            content: {
                TerminalHighlightRuleFields(rule: $rule)
                if let error = model.storageError { Section { Text(error).foregroundStyle(.red) } }
            }
        )
    }

    private var toolbarActions: [MobileEditorToolbarAction] {
        guard !isNew, !rule.isBuiltIn else { return [] }
        return [
            MobileEditorToolbarAction(
                id: "delete", title: AppStrings.Common.delete, systemImage: "trash", role: .destructive,
                perform: {
                    var next = model.preferences
                    next.rules.removeAll { $0.id == rule.id }
                    if model.save(next) { dismiss() }
                })
        ]
    }
}
