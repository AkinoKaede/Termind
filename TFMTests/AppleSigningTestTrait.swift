// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Real Keychain and CloudKit integration requires a provisioned test host, not ad-hoc signing.
    static var requiresAppleSigning: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["TERMIND_SIGNED_INTEGRATION_TESTS"] == "1",
            "Set TERMIND_SIGNED_INTEGRATION_TESTS=1 with valid signing to run Keychain and CloudKit integration tests"
        )
    }
}
