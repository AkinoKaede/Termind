// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// UIKit key-window and presentation state is shared by every suite in the test host.
    static var requiresKeyWindow: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
            "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"
        )
    }
}
