import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Shared connection-state composition for interactive sessions.
/// Transport-specific models own their I/O, while this object owns the common
/// connection journey and retry lifecycle shown by both Terminal and SFTP.
@Observable
public final class RemoteSessionConnectionController {
    public let journey = ConnectionJourney()
    public let keyboardAuthentication = SSHKeyboardInteractiveQueue()
    private var keyboardAuthenticationID: UUID?
    public let reconnect: SessionReconnectController
    public private(set) var pendingHostKey: SSHHostKeyPrompt?
    public var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    public private(set) var hasConnectedOnce = false
    public private(set) var isRecovering = false
    private var pendingHostKeyHostID: Host.ID?
    private var hostKeyAuthorizationID: UUID?
    private var hostKeyAuthorization: CheckedContinuation<SSHHostKeyDecision, Never>?

    public var reconnectState: ReconnectState? { reconnect.state }

    public init(reconnect: SessionReconnectController = SessionReconnectController()) {
        self.reconnect = reconnect
    }

    public func disconnect() {
        keyboardAuthenticationID = nil
        keyboardAuthentication.cancelAll()
        finishHostKeyAuthorization(.reject)
        temporaryHostKeys.removeAll()
        reconnect.stop()
        hasConnectedOnce = false
        isRecovering = false
        journey.hide()
    }

    @discardableResult
    public func markConnected() -> Bool {
        let wasRecovering = isRecovering
        let initial = !hasConnectedOnce
        hasConnectedOnce = true
        isRecovering = false
        reconnect.markConnected(initial: initial)
        return wasRecovering
    }

    @discardableResult
    public func scheduleRecovery(
        after error: String, retry: @escaping SessionReconnectController.RetryAction
    ) -> Bool {
        guard hasConnectedOnce else { return false }
        let announcesLoss = !isRecovering
        isRecovering = true
        reconnect.schedule(after: error, retry: retry)
        return announcesLoss
    }

    public func pauseForUserInteraction() {
        reconnect.pauseForUserInteraction()
    }

    @discardableResult
    public func stopRecovery() -> ReconnectState? {
        let state = reconnect.state
        reconnect.stop()
        isRecovering = false
        return state
    }

    public func suspendForForegroundResume(reconnecting: Bool) {
        reconnect.stop()
        isRecovering = reconnecting && hasConnectedOnce
    }

    public func resetRecovery() {
        reconnect.stop()
        hasConnectedOnce = false
        isRecovering = false
    }

    public func trustHostKey(
        _ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore
    ) {
        guard pendingHostKey?.observation == observation else { return }
        store.trust(
            KnownHostEntry(
                hostname: observation.hostname, port: observation.port,
                algorithm: observation.algorithm, fingerprint: observation.fingerprint,
                addedAt: Date()
            ))
        if let pendingHostKeyHostID { temporaryHostKeys[pendingHostKeyHostID] = nil }
        finishHostKeyAuthorization(.accept)
        journey.resume()
    }

    public func useTemporaryHostKey(_ observation: SSHHostKeyObservation) -> Bool {
        guard pendingHostKey?.observation == observation,
            let pendingHostKeyHostID
        else { return false }
        temporaryHostKeys[pendingHostKeyHostID] = observation.identity
        finishHostKeyAuthorization(.accept)
        journey.resume()
        return true
    }

    public func rejectHostKey() { finishHostKeyAuthorization(.reject) }

    public func answerKeyboardInteractive(_ challenge: SSHKeyboardInteractiveChallenge) async throws -> [String] {
        try Task.checkCancellation()
        keyboardAuthenticationID = challenge.id
        reconnect.pauseForUserInteraction()
        journey.waitForAuthentication(at: challenge.hostID)
        defer {
            if keyboardAuthenticationID == challenge.id {
                keyboardAuthenticationID = nil
                journey.resume()
            }
        }
        return try await keyboardAuthentication.request(challenge)
    }

    public func authorizeHostKey(
        _ challenge: SSHHostKeyChallenge,
        using store: any RemoteSessionHostStore,
        uriFingerprintMatched: Bool = false
    ) async -> SSHHostKeyDecision {
        if challenge.expectedHostKeys.contains(challenge.observation.identity) {
            return .accept
        }
        finishHostKeyAuthorization(.reject)
        if !challenge.expectedHostKeys.isEmpty {
            store.markKnownHostMismatched(
                hostname: challenge.observation.hostname,
                port: challenge.observation.port
            )
        }
        let authorizationID = UUID()
        hostKeyAuthorizationID = authorizationID
        waitForHostKey(
            SSHHostKeyPrompt(
                observation: challenge.observation,
                kind: challenge.expectedHostKeys.isEmpty
                    ? .firstUse
                    : .additionalKey(trustedKeyCount: challenge.expectedHostKeys.count),
                uriFingerprintMatched: uriFingerprintMatched
            ),
            hostID: challenge.hostID,
            fingerprint: challenge.observation.fingerprint
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard hostKeyAuthorizationID == authorizationID else {
                    continuation.resume(returning: .reject)
                    return
                }
                hostKeyAuthorization = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelHostKeyAuthorization(id: authorizationID)
            }
        }
    }

    public func authorizeHostKey(
        _ challenge: SSHHostKeyChallenge,
        using store: any RemoteSessionHostStore,
        uriFingerprint: SSHURIHostKeyFingerprint?,
        destinationHostID: Host.ID
    ) async -> SSHHostKeyDecision {
        guard challenge.hostID == destinationHostID, let uriFingerprint else {
            return await authorizeHostKey(challenge, using: store)
        }
        guard uriFingerprint.matches(challenge.observation) else { return .reject }
        if !challenge.expectedHostKeys.isEmpty {
            return challenge.expectedHostKeys.contains(challenge.observation.identity) ? .accept : .reject
        }
        return await authorizeHostKey(
            challenge, using: store, uriFingerprintMatched: true)
    }

    public func waitForHostKey(
        _ prompt: SSHHostKeyPrompt, hostID: Host.ID, fingerprint: String
    ) {
        pendingHostKey = prompt
        pendingHostKeyHostID = hostID
        reconnect.pauseForUserInteraction()
        journey.waitForHostKey(at: hostID, fingerprint: fingerprint)
    }

    public func progressHandler(
        attemptID: UUID, isCurrent: @escaping @MainActor @Sendable (UUID) -> Bool
    ) -> SSHRouteProgressHandler {
        { [weak self] event in
            Task { @MainActor in
                guard isCurrent(attemptID) else { return }
                self?.journey.receive(event)
            }
        }
    }

    public func presentReconnectJourney(
        host: Host?, using store: any RemoteSessionHostStore,
        purpose: ConnectionPurpose, username: String?
    ) {
        guard let host else { return }
        journey.begin(
            host: host, route: store.route(for: host), purpose: purpose,
            username: username, mode: .reconnection
        )
    }

    public func clearHostKeyPrompt() {
        finishHostKeyAuthorization(.reject)
    }

    private func cancelHostKeyAuthorization(id: UUID) {
        guard hostKeyAuthorizationID == id else { return }
        finishHostKeyAuthorization(.reject)
    }

    private func finishHostKeyAuthorization(_ decision: SSHHostKeyDecision) {
        let continuation = hostKeyAuthorization
        hostKeyAuthorization = nil
        hostKeyAuthorizationID = nil
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        continuation?.resume(returning: decision)
    }
}
