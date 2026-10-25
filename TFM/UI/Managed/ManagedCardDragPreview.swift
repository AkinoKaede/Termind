// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

extension EnvironmentValues {
    @Entry var managedCardIsDragPreview = false
}

/// Render the actual card at its source size, independently of the insertion slot.
struct ManagedCardDragPreview<Content: View>: View {
    let size: CGSize?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size?.width, height: size?.height)
            .environment(\.managedCardIsDragPreview, true)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ManagedCardReorderPlaceholder: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
