import SwiftUI

/// The same system artwork in a host row and a workspace's Live Activity link.
public struct HostSystemIcon: View {
    public enum Style {
        case standard
        case desktopCard
    }

    private let asset: String?
    private let size: CGFloat
    private let showsBackground: Bool
    private let style: Style

    public init(asset: String?, size: CGFloat = 32, showsBackground: Bool = true, style: Style = .standard) {
        self.asset = asset
        self.size = size
        self.showsBackground = showsBackground
        self.style = style
    }

    public var body: some View {
        Group {
            if let asset {
                Image(asset, bundle: .main).resizable().scaledToFit()
            } else if style == .desktopCard {
                Image(systemName: "server.rack").font(.system(size: 14, weight: .medium))
            } else {
                Image(systemName: "server.rack").resizable().scaledToFit()
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
