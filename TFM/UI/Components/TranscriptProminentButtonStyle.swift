// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

private struct TranscriptProminentButtonModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            // The enabled accent background needs its contrasting foreground.
            // Disabled buttons have a neutral background instead.
            .foregroundStyle(isEnabled ? TermindColor.transcriptProminentForeground : TermindColor.primaryForeground)
    }
}

extension View {
    func transcriptProminentButtonStyle() -> some View {
        modifier(TranscriptProminentButtonModifier())
    }
}
