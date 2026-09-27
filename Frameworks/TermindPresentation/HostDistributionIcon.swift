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
        let entry = LinuxDistributionIconCatalog.entry(for: host?.detectedDistribution)
        let tint =
            host?.colorTag.color
            ?? entry.flatMap { LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme) }
            ?? .accentColor
        HostSystemIcon(asset: entry?.asset, size: size, style: artworkStyle)
            .tint(tint)
    }
}
