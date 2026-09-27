import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

struct ConnectionStatusPresentationTests {
    @Test func disconnectedIconsOnlyKeepTheirBadgeForUnreadOutput() {
        #expect(!ConnectionStatus.disconnected.showsIconBadge())
        #expect(ConnectionStatus.disconnected.showsIconBadge(hasUnread: true))
        for status: ConnectionStatus in [.connecting, .reconnecting, .connected, .failed("Unavailable")] {
            #expect(status.showsIconBadge())
        }
    }

    @Test func connectionProgressTakesPrecedenceOverUnreadOutput() {
        for status: ConnectionStatus in [.connecting, .reconnecting] {
            #expect(status.indicatorTint(hasUnread: true) == .orange)
        }
        for status: ConnectionStatus in [.connected, .disconnected, .failed("Unavailable")] {
            #expect(status.indicatorTint(hasUnread: true) == .accentColor)
        }
        #expect(ConnectionStatus.connected.indicatorTint() == .green)
        #expect(ConnectionStatus.failed("Unavailable").indicatorTint() == .red)
        #expect(ConnectionStatus.disconnected.indicatorTint() == .secondary)
    }

    @Test func failureDetailsRemainAvailableToAccessibilityAndHelp() {
        #expect(ConnectionStatus.failed("Connection refused").label == "Connection refused")
    }
}
