// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

public struct NotificationUnreadDot: View {
    public init() {}
    public var body: some View {
        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
