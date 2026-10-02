import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain

@MainActor
public enum TerminalKeywordHighlighting {
    public static func runtimeRule(_ rule: TerminalHighlightRule, environment: EnvironmentValues)
        -> TerminalKeywordHighlightRule
    {
        func rgb(_ tag: TagColor) -> UInt32? {
            guard let color = tag.color?.resolve(in: environment) else { return nil }
            func component(_ value: Float) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
            return component(color.red) << 16 | component(color.green) << 8 | component(color.blue)
        }
        return TerminalKeywordHighlightRule(
            pattern: rule.pattern, mode: rule.mode == .text ? .text : .regularExpression,
            isCaseSensitive: rule.isCaseSensitive,
            foregroundRGB: rgb(rule.color), backgroundRGB: rgb(rule.backgroundColor))
    }

    public static func validationIssue(_ rule: TerminalHighlightRule) -> String? {
        TerminalKeywordHighlightRule(
            pattern: rule.pattern, mode: rule.mode == .text ? .text : .regularExpression,
            isCaseSensitive: rule.isCaseSensitive, foregroundRGB: 0
        ).validationIssue()
    }

    public static func name(_ rule: TerminalHighlightRule) -> String {
        let defaults = TerminalHighlightPreferences.builtInRules
        guard let index = defaults.firstIndex(where: { $0.id == rule.id && $0.name == rule.name }) else {
            return rule.name
        }
        let titles: [LocalizedStringResource] = [
            AppStrings.TerminalHighlighting.error, AppStrings.TerminalHighlighting.warning,
            AppStrings.TerminalHighlighting.ok, AppStrings.TerminalHighlighting.info,
            AppStrings.TerminalHighlighting.debug, AppStrings.TerminalHighlighting.addresses,
        ]
        return String(localized: titles[index])
    }
}

private struct TerminalKeywordHighlightModifier: ViewModifier {
    let state: TerminalViewState
    let model: TerminalHighlightSettingsModel
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        let rules =
            model.preferences.isEnabled
            ? model.preferences.effectiveRules.map {
                TerminalKeywordHighlighting.runtimeRule($0, environment: environment)
            } : []
        content.task(id: rules) {
            // Preserve usable rules if a remote pattern is unsupported by this engine version.
            state.setKeywordHighlightRules(rules.filter { $0.validationIssue() == nil })
        }
    }
}

extension View {
    public func terminalKeywordHighlighting(state: TerminalViewState, model: TerminalHighlightSettingsModel)
        -> some View
    {
        modifier(TerminalKeywordHighlightModifier(state: state, model: model))
    }
}
