import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Window presentation and focus changes require an explicit opt-in, even on a machine with a display.
    static var requiresVisibleWindow: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["TERMIND_WINDOW_TESTS"] == "1",
            "Set TERMIND_WINDOW_TESTS=1 to run tests that show windows or take focus"
        )
    }
}
