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
                    set: { enabled in update { $0.isEnabled = enabled } }))
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
                    Button(AppStrings.TerminalHighlighting.moveUp.swiftUIKey) { move(rule.id, by: -1) }
                        .disabled(model.preferences.rules.first?.id == rule.id)
                    Button(AppStrings.TerminalHighlighting.moveDown.swiftUIKey) { move(rule.id, by: 1) }
                        .disabled(model.preferences.rules.last?.id == rule.id)
                    Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                        update { $0.rules.removeAll { $0.id == rule.id } }
                    }
                }
            }
            .onMove { indices, destination in update { $0.rules.move(fromOffsets: indices, toOffset: destination) }
            }
            if showsAddRule {
                FormNavigationAction(title: AppStrings.TerminalHighlighting.addRule) {
                    edit(TerminalHighlightRule())
                }.disabled(model.preferences.rules.count >= TerminalHighlightPreferences.maximumCustomRuleCount)
            }
            if model.preferences.rules.count >= TerminalHighlightPreferences.maximumCustomRuleCount {
                Text(AppStrings.TerminalHighlighting.ruleLimit).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
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

    private func update(_ edit: (inout TerminalHighlightPreferences) -> Void) {
        var next = model.preferences
        edit(&next)
        model.save(next)
    }

    private func move(_ id: UUID, by offset: Int) {
        update { value in
            guard let index = value.rules.firstIndex(where: { $0.id == id }),
                value.rules.indices.contains(index + offset)
            else { return }
            value.rules.swapAt(index, index + offset)
        }
    }
}
