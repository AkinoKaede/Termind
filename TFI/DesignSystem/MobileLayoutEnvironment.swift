// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

nonisolated enum MobileLayout: Sendable {
    case compact
    case regular

    init(sizeClass: UserInterfaceSizeClass?) {
        self = sizeClass == .regular ? .regular : .compact
    }
}

extension EnvironmentValues {
    @Entry var mobileLayout: MobileLayout? = nil
}
