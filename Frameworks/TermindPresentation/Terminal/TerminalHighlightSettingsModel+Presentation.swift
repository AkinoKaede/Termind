import Foundation
import TermindApplication

extension TerminalHighlightSettingsModel {
    public var failureMessage: String? {
        switch failure {
        case .storage(let message): message
        case .validation(.invalidPattern(let detail)):
            String(localized: AppStrings.TerminalHighlighting.invalidPattern) + "\n" + detail
        case .validation(.ruleLimit): String(localized: AppStrings.TerminalHighlighting.ruleLimit)
        case .validation(.builtIn), .validation(.invalidRule): String(localized: AppStrings.TerminalHighlighting.limits)
        case nil: nil
        }
    }
}
