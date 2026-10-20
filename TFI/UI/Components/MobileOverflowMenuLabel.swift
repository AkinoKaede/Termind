// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Keeps every mobile overflow menu on the same symbol while preserving a contextual accessible name.
struct MobileOverflowMenuLabel: View {
    let title: LocalizedStringResource

    init(_ title: LocalizedStringResource) {
        self.title = title
    }

    var body: some View {
        Label(title, systemImage: "ellipsis")
            .labelStyle(.iconOnly)
    }
}
