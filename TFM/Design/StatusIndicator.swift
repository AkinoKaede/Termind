import SwiftUI
import TermindDomain

/// The shared visual vocabulary for connection state.
///
/// Sidebar rows, workspace items, and the status bar all render the same dot, so a
/// color means one thing everywhere in the window.
extension ConnectionStatus {
    var tint: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting, .reconnecting: TermindColor.warning
        case .connected: TermindColor.success
        case .failed: TermindColor.danger
        }
    }

    var label: String {
        switch self {
        case .disconnected: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting")
        case .failed(let message): message
        }
    }
}

/// A connection-state dot. Pulses while a connection is being established, and
/// turns blue when a background workspace has produced output the user has not seen.
struct StatusDot: View {
    let status: ConnectionStatus
    var hasUnread: Bool = false
    var size: CGFloat = Metrics.Sidebar.statusDot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        let animatesPulse = isPulsing && !reduceMotion

        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .opacity(animatesPulse ? 0.3 : 1)
            // A repeating animation must disappear when the status settles.
            // Reusing it for the transition back to `false` leaves SwiftUI's
            // display link running even though the dot looks stationary.
            .animation(animatesPulse ? Motion.statusPulse : nil, value: animatesPulse)
            .onAppear { isPulsing = status.isBusy }
            .onChange(of: status.isBusy) { _, busy in isPulsing = busy }
            .accessibilityLabel(Text(status.label))
    }

    /// Unread output only shows once the connection has settled — while
    /// connecting, the connection state is the more useful thing to signal.
    private var fill: Color {
        hasUnread && !status.isBusy ? TermindColor.accent : status.tint
    }
}
