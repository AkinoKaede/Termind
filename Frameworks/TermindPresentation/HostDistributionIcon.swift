// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

/// Shared host artwork, independent of connection state.
public struct HostDistributionIcon: View {
    private let host: TermindDomain.Host?
    private let size: CGFloat
    private let artworkStyle: HostSystemIcon.Style

    @Environment(\.colorScheme) private var colorScheme

    public init(host: TermindDomain.Host?, size: CGFloat = 36, artworkStyle: HostSystemIcon.Style = .standard) {
        self.host = host
        self.size = size
        self.artworkStyle = artworkStyle
    }

    public var body: some View {
        let entry = HostIconCatalog.resolvedEntry(for: host)
        let tint =
            host?.colorTag.color
            ?? entry.flatMap { HostIconBrandColor.color(hex: $0.hex, colorScheme: colorScheme) }
            ?? .accentColor
        HostSystemIcon(artwork: HostIconCatalog.resolvedArtwork(for: host), size: size, style: artworkStyle)
            .tint(tint)
    }
}
