import SwiftUI
import TermindApplication
import TermindDomain

public struct TerminalHighlightSettingsSection: View {
    private let model: TerminalHighlightSettingsModel
    private let showsTitle: Bool
    private let showsAddRule: Bool
    private let edit: (TerminalHighlightRule) -> Void

    public init(
        model: TerminalHighlightSettingsModel, showsTitle: Bool = true, showsAddRule: Bool = true,
        edit: @escaping (TerminalHighlightRule) -> Void
    ) {
        self.model = model
        self.showsTitle = showsTitle
        self.showsAddRule = showsAddRule
        self.edit = edit
    }

    public var body: some View {
        Section {
            Toggle(
                AppStrings.Common.enabled.swiftUIKey,
                isOn: Binding(
                    get: { model.preferences.isEnabled },
                    set: { model.setEnabled($0) }))
            ForEach(TerminalHighlightPreferences.builtInRules) { rule in
                ruleLabel(rule)
            }
            ForEach(model.preferences.rules) { rule in
                Button {
                    edit(rule)
                } label: {
                    ruleLabel(rule)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(AppStrings.Common.edit.swiftUIKey) { edit(rule) }
                    Button(AppStrings.TerminalHighlighting.moveUp.swiftUIKey) { model.move(rule.id, by: -1) }
                        .disabled(!model.canMove(rule.id, by: -1))
                    Button(AppStrings.TerminalHighlighting.moveDown.swiftUIKey) { model.move(rule.id, by: 1) }
                        .disabled(!model.canMove(rule.id, by: 1))
                    Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                        model.delete(rule.id)
                    }
                }
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
            if showsAddRule {
                FormNavigationAction(title: AppStrings.TerminalHighlighting.addRule) {
                    edit(TerminalHighlightRule())
                }.disabled(!model.canAddRule)
            }
            if !model.canAddRule {
                Text(AppStrings.TerminalHighlighting.ruleLimit).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.failureMessage { Text(error).foregroundStyle(.red) }
        } header: {
            if showsTitle { Text(AppStrings.TerminalHighlighting.title) }
        } footer: {
            Text(AppStrings.TerminalHighlighting.explanation)
        }
    }

    private func ruleLabel(_ rule: TerminalHighlightRule) -> some View {
        HStack(spacing: 12) {
            Image(
                systemName: rule.color == .none && rule.backgroundColor == .none
                    ? "circle.dashed" : "circle.fill"
            )
            .foregroundStyle(rule.color.color ?? rule.backgroundColor.color ?? .secondary)
            .frame(width: 14, height: 14)
            Text(TerminalKeywordHighlighting.name(rule)).foregroundStyle(.primary)
            Spacer()
        }.contentShape(.rect)
    }

}
