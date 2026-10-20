// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The same system artwork in a host row and a workspace's Live Activity link.
public struct HostSystemIcon: View {
    public enum Style {
        case standard
        case desktopCard
    }

    private let artwork: HostIconArtwork
    private let size: CGFloat
    private let showsBackground: Bool
    private let style: Style

    public init(
        asset: String?, systemImageName: String? = nil, size: CGFloat = 32,
        showsBackground: Bool = true, style: Style = .standard
    ) {
        self.init(
            artwork: asset.map(HostIconArtwork.asset)
                ?? .systemImage(systemImageName ?? HostGeneralIcon.server.systemImageName),
            size: size, showsBackground: showsBackground, style: style)
    }

    public init(
        artwork: HostIconArtwork, size: CGFloat = 32, showsBackground: Bool = true, style: Style = .standard
    ) {
        self.artwork = artwork
        self.size = size
        self.showsBackground = showsBackground
        self.style = style
    }

    public var body: some View {
        Group {
            if artwork.systemImageName != nil, style == .desktopCard {
                artwork.image.font(.system(size: 14, weight: .medium))
            } else {
                artwork.image.resizable().scaledToFit()
            }
        }
        .foregroundStyle(.tint)
        .padding(showsBackground ? (style == .desktopCard ? 7 : size * 0.2) : 0)
        .frame(width: size, height: size)
        .background(
            .tint.opacity(showsBackground ? 0.16 : 0),
            in: RoundedRectangle(cornerRadius: style == .desktopCard ? 6 : size * 0.25)
        )
        .accessibilityHidden(true)
    }
}
