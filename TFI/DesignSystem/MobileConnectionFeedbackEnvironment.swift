// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct MobileConnectionFeedbackContext {
    var isForeground: @MainActor () -> Bool = { false }
    var succeeded: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    @Entry var mobileConnectionFeedback = MobileConnectionFeedbackContext()
}
