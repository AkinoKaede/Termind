// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// A compact identity chip shared by sidebar items and workspace panes.
struct ItemDragPreview: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.body)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
            .fixedSize()
            .background(.regularMaterial, in: .rect(cornerRadius: Metrics.Radius.medium))
    }
}
