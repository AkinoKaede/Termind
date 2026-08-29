import Foundation

/// Shared connection-state composition for SSH-backed interactive sessions.
/// Transport-specific models own their I/O, while this object owns the common
/// connection journey and retry lifecycle shown by both Terminal and SFTP.
@Observable
final class RemoteSessionConnectionController {
    let journey = SSHConnectionJourney()
    let reconnect = SessionReconnectController()

    var reconnectState: ReconnectState? { reconnect.state }

    func retryNow() { reconnect.retryNow() }
    func stopReconnecting() { reconnect.stop() }

    func disconnect() {
        reconnect.stop()
        journey.hide()
    }
}
