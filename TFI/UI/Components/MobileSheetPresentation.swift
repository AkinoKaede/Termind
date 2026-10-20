// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Sheets follow the presenting window without replacing a saving editor's content.
private struct MobileSheetPresentation: ViewModifier {
    var compact: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.mobileLayout) private var windowLayout
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        let regular = (windowLayout ?? MobileLayout(sizeClass: sizeClass)) == .regular
        content
            .presentationSizing(MobileSheetSizing(regular: regular))
            .presentationDetents(!regular && compact && !typeSize.isAccessibilitySize ? [.medium, .large] : [.large])
            .presentationDragIndicator(regular ? .hidden : .visible)
    }
}

private nonisolated struct MobileSheetSizing: PresentationSizing {
    let regular: Bool

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        if regular {
            FormPresentationSizing.form.proposedSize(for: root, context: context)
        } else {
            AutomaticPresentationSizing.automatic.proposedSize(for: root, context: context)
        }
    }
}

extension View {
    func mobileSheetPresentation(compact: Bool = false) -> some View {
        modifier(MobileSheetPresentation(compact: compact))
    }
}
