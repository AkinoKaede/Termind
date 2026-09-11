import SwiftUI

/// The same system artwork in a host row and a workspace's Live Activity link.
public struct HostSystemIcon: View {
    private let asset: String?
    private let size: CGFloat
    private let showsBackground: Bool

    public init(asset: String?, size: CGFloat = 32, showsBackground: Bool = true) {
        self.asset = asset
        self.size = size
        self.showsBackground = showsBackground
    }

    public var body: some View {
        Group {
            if let asset {
                Image(asset, bundle: .main).resizable().scaledToFit()
            } else {
                Image(systemName: "server.rack").resizable().scaledToFit()
            }
        }
        .foregroundStyle(.tint)
        .padding(showsBackground ? size * 0.2 : 0)
        .frame(width: size, height: size)
        .background(.tint.opacity(showsBackground ? 0.16 : 0), in: RoundedRectangle(cornerRadius: size * 0.25))
        .accessibilityHidden(true)
    }
}
