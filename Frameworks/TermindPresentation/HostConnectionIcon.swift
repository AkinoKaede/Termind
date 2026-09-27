import SwiftUI
import TermindDomain

/// Shared host artwork with an optional connection-state badge.
public struct HostConnectionIcon: View {
    private let host: TermindDomain.Host?
    private let size: CGFloat
    private let artworkStyle: HostSystemIcon.Style
    private let status: ConnectionStatus?
    private let badgeStyle: ConnectionBadgeStyle

    public init(
        host: TermindDomain.Host?, size: CGFloat = 36, artworkStyle: HostSystemIcon.Style = .standard,
        status: ConnectionStatus? = nil, badgeStyle: ConnectionBadgeStyle = .card(background: .clear)
    ) {
        self.host = host
        self.size = size
        self.artworkStyle = artworkStyle
        self.status = status
        self.badgeStyle = badgeStyle
    }

    public var body: some View {
        ConnectionStatusIcon(status: status, style: badgeStyle) {
            HostDistributionIcon(host: host, size: size, artworkStyle: artworkStyle)
        }
    }
}
