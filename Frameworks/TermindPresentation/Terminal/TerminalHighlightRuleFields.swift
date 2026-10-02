import SwiftUI
import TermindApplication
import TermindDomain

public struct TerminalHighlightRuleFields: View {
    @Binding private var rule: TerminalHighlightRule

    private let model: TerminalHighlightSettingsModel

    public init(rule: Binding<TerminalHighlightRule>, model: TerminalHighlightSettingsModel) {
        _rule = rule
        self.model = model
    }

    private var patternIssue: String? {
        model.patternValidationIssue(for: rule)
    }

    public var body: some View {
        Group {
            Section {
                LabeledContent(AppStrings.Common.name.swiftUIKey) {
                    TextField(AppStrings.Common.name.swiftUIKey, text: $rule.name)
                        .labelsHidden().multilineTextAlignment(.trailing)
                }
                Picker(AppStrings.TerminalHighlighting.mode.swiftUIKey, selection: $rule.mode) {
                    Text(AppStrings.TerminalHighlighting.text).tag(TerminalHighlightRule.MatchMode.text)
                    Text(AppStrings.TerminalHighlighting.regex).tag(
                        TerminalHighlightRule.MatchMode.regularExpression)
                }
                TextField(AppStrings.TerminalHighlighting.pattern.swiftUIKey, text: $rule.pattern, axis: .vertical)
                    .labelsHidden().multilineTextAlignment(.leading)
                    .font(.body.monospaced()).lineLimit(2...6).autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                if let patternIssue {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppStrings.TerminalHighlighting.invalidPattern).foregroundStyle(.red)
                        Text(patternIssue).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(AppStrings.TerminalHighlighting.caseSensitive.swiftUIKey, isOn: $rule.isCaseSensitive)
            }
            Section(AppStrings.TerminalHighlighting.foreground.swiftUIKey) {
                ColorTagPicker(selection: $rule.color, layout: .touch)
            }
            Section(AppStrings.TerminalHighlighting.background.swiftUIKey) {
                ColorTagPicker(selection: $rule.backgroundColor, layout: .touch)
            }
            if rule.name.utf8.count > 256 || rule.pattern.utf8.count > 16384 {
                Section {
                    Text(AppStrings.TerminalHighlighting.limits).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
