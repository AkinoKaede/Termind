import Foundation

/// Shared connection-state composition for interactive sessions.
/// Transport-specific models own their I/O, while this object owns the common
/// connection journey and retry lifecycle shown by both Terminal and SFTP.
@Observable
final class RemoteSessionConnectionController {
    let journey = ConnectionJourney()
    let reconnect = SessionReconnectController()
    var pendingHostKey: SSHHostKeyPrompt?
    var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    private var pendingHostKeyHostID: Host.ID?

    var reconnectState: ReconnectState? { reconnect.state }

    func disconnect() {
        clearHostKeyPrompt()
        temporaryHostKeys.removeAll()
        reconnect.stop()
        journey.hide()
    }

    func trustHostKey(
        _ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore
    ) {
        store.trust(
            KnownHostEntry(
                hostname: observation.hostname, port: observation.port,
                algorithm: observation.algorithm, fingerprint: observation.fingerprint,
                addedAt: Date()
            ))
        if let pendingHostKeyHostID { temporaryHostKeys[pendingHostKeyHostID] = nil }
        clearHostKeyPrompt()
        journey.resume()
    }

    func useTemporaryHostKey(_ observation: SSHHostKeyObservation) -> Bool {
        guard let pendingHostKeyHostID else { return false }
        temporaryHostKeys[pendingHostKeyHostID] = observation.identity
        clearHostKeyPrompt()
        journey.resume()
        return true
    }

    func waitForHostKey(
        _ prompt: SSHHostKeyPrompt, hostID: Host.ID, fingerprint: String
    ) {
        pendingHostKey = prompt
        pendingHostKeyHostID = hostID
        reconnect.pauseForUserInteraction()
        journey.waitForHostKey(at: hostID, fingerprint: fingerprint)
    }

    func progressHandler(
        attemptID: UUID, isCurrent: @escaping @MainActor @Sendable (UUID) -> Bool
    ) -> SSHRouteProgressHandler {
        { [weak self] event in
            Task { @MainActor in
                guard isCurrent(attemptID) else { return }
                self?.journey.receive(event)
            }
        }
    }

    func presentReconnectJourney(
        host: Host?, using store: any RemoteSessionHostStore,
        purpose: ConnectionPurpose, username: String?
    ) {
        guard let host else { return }
        journey.begin(
            host: host, route: store.route(for: host), purpose: purpose,
            username: username, mode: .reconnection
        )
    }

    private func clearHostKeyPrompt() {
        pendingHostKey = nil
        pendingHostKeyHostID = nil
    }
}
