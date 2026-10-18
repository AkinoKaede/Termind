import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SSHHostKeyAuthorizationRequest: Hashable, Sendable {
    public var hostID: Host.ID
    public var prompt: SSHHostKeyPrompt

    public init(hostID: Host.ID, prompt: SSHHostKeyPrompt) {
        self.hostID = hostID
        self.prompt = prompt
    }
}

/// One MainActor owner for a single interactive host-key decision. Feature
/// models keep their own lifecycle and presentation state while sharing the
/// continuation, cancellation, and temporary/persistent trust rules.
@MainActor
@Observable
public final class SSHHostKeyAuthorizationCoordinator {
    public private(set) var pending: SSHHostKeyAuthorizationRequest?
    public var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    private var authorizationID: UUID?
    private var continuation: CheckedContinuation<SSHHostKeyDecision, Never>?

    public init() {}

    public func authorize(
        _ challenge: SSHHostKeyChallenge,
        onPrompt: (SSHHostKeyAuthorizationRequest) -> Void = { _ in }
    ) async -> SSHHostKeyDecision {
        if challenge.expectedHostKeys.contains(challenge.observation.identity) { return .accept }
        finish(.reject)
        let id = UUID()
        authorizationID = id
        let request = SSHHostKeyAuthorizationRequest(
            hostID: challenge.hostID,
            prompt: SSHHostKeyPrompt(challenge: challenge))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard authorizationID == id else {
                    continuation.resume(returning: .reject)
                    return
                }
                self.continuation = continuation
                pending = request
                onPrompt(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    @discardableResult
    public func continueOnce(_ observation: SSHHostKeyObservation) -> Bool {
        guard pending?.prompt.observation == observation, let hostID = pending?.hostID else { return false }
        temporaryHostKeys[hostID] = observation.identity
        finish(.accept)
        return true
    }

    @discardableResult
    public func trust(
        _ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore,
        addedAt: Date = .now
    ) -> Bool {
        guard pending?.prompt.observation == observation, let hostID = pending?.hostID else { return false }
        store.trust(
            KnownHostEntry(
                hostname: observation.hostname, port: observation.port,
                algorithm: observation.algorithm, fingerprint: observation.fingerprint,
                addedAt: addedAt))
        temporaryHostKeys[hostID] = nil
        finish(.accept)
        return true
    }

    public func reject() { finish(.reject) }

    public func cancelPending() { finish(.reject) }

    public func reset() {
        finish(.reject)
        temporaryHostKeys.removeAll()
    }

    private func cancel(id: UUID) {
        guard authorizationID == id else { return }
        finish(.reject)
    }

    private func finish(_ decision: SSHHostKeyDecision) {
        let continuation = continuation
        self.continuation = nil
        authorizationID = nil
        pending = nil
        continuation?.resume(returning: decision)
    }
}

/// Shared connection-state composition for interactive sessions.
/// Transport-specific models own their I/O, while this object owns the common
/// connection journey and retry lifecycle shown by both Terminal and SFTP.
@Observable
public final class RemoteSessionConnectionController {
    public var connectionRoute: SSHConnectionRoute?
    public var transientHost: Host?
    public var connectionAttemptID: UUID?
    public var pendingAuthentication: SSHAuthenticationPrompt?
    public var suppliedAuthentications: [Host.ID: SSHAuthenticationSubmission] = [:]
    public var suppliedProxyAuthentications: [Host.ID: SSHProxyAuthenticationSubmission] = [:]

    public func connectionHost(
        _ id: Host.ID, destinationID: Host.ID, using store: any RemoteSessionHostStore
    ) -> Host? {
        connectionRoute?.host(id) ?? store.host(id) ?? (id == destinationID ? transientHost : nil)
    }

    public let journey = ConnectionJourney()
    public let securityKeySigning = SecurityKeySigningCoordinator()
    public let keyboardAuthentication = SSHKeyboardInteractiveQueue()
    public let hostKeyAuthorization = SSHHostKeyAuthorizationCoordinator()
    private var keyboardAuthenticationID: UUID?
    public let reconnect: SessionReconnectController
    public var pendingHostKey: SSHHostKeyPrompt? { hostKeyAuthorization.pending?.prompt }
    public var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] {
        get { hostKeyAuthorization.temporaryHostKeys }
        set { hostKeyAuthorization.temporaryHostKeys = newValue }
    }
    public private(set) var hasConnectedOnce = false
    public private(set) var isRecovering = false

    public var reconnectState: ReconnectState? { reconnect.state }

    public init(reconnect: SessionReconnectController = SessionReconnectController()) {
        self.reconnect = reconnect
    }

    public func disconnect() {
        pendingAuthentication = nil
        suppliedAuthentications.removeAll()
        suppliedProxyAuthentications.removeAll()
        keyboardAuthenticationID = nil
        keyboardAuthentication.cancelAll()
        securityKeySigning.cancel()
        hostKeyAuthorization.reset()
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

    /// Retire channel-owned work before presenting recovery or arming a retry.
    /// Only terminal sessions supply their frozen route for the recovery journey.
    public func scheduleReconnect(
        after message: String, hostID: Host.ID, using store: any RemoteSessionHostStore,
        purpose: ConnectionPurpose, route: SSHConnectionRoute? = nil, usernameHint: String? = nil,
        teardown: () -> Void,
        retry: @escaping @MainActor (any RemoteSessionHostStore) -> Void
    ) {
        teardown()
        let host = connectionHost(hostID, destinationID: hostID, using: store)
        if let route, let host {
            journey.begin(
                host: host, route: route.hosts, purpose: purpose,
                username: route.usernames[host.id], mode: .reconnection
            )
        } else {
            presentReconnectJourney(
                host: host, using: store, purpose: purpose,
                username: host.flatMap { store.identity(for: $0)?.username } ?? usernameHint
            )
        }
        scheduleRecovery(after: message) { [weak store] in
            guard let store else { return }
            retry(store)
        }
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

    /// Capture before resetting recovery on failure. Visibility is not evidence that
    /// a transport is bootstrapping: restored sessions can fail before showing a Journey.
    public func transportJourneyContext(restoring: Bool = false) -> ConnectionJourney.TransportContext {
        hasConnectedOnce || isRecovering || restoring || journey.transportRecovery != nil
            ? .recovery : .initialConnection
    }

    public func resetRecovery() {
        reconnect.stop()
        hasConnectedOnce = false
        isRecovering = false
    }

    public func trustHostKey(
        _ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore
    ) {
        guard hostKeyAuthorization.trust(observation, using: store) else { return }
        journey.resume()
    }

    public func useTemporaryHostKey(_ observation: SSHHostKeyObservation) -> Bool {
        guard hostKeyAuthorization.continueOnce(observation) else { return false }
        journey.resume()
        return true
    }

    public func signWithSecurityKey(_ request: SecurityKeySigningRequest) async throws -> SecurityKeyAssertion {
        reconnect.pauseForUserInteraction()
        journey.waitForAuthentication(at: request.hostID)
        do {
            let assertion = try await securityKeySigning.sign(request)
            try Task.checkCancellation()
            journey.resume()
            return assertion
        } catch {
            // Cancellation is not an accepted authentication checkpoint.
            if journey.phase == .waiting {
                journey.fail(
                    error is CancellationError
                        ? String(localized: "Authentication was cancelled. Retry to continue connecting.")
                        : error.localizedDescription,
                    at: request.hostID)
            }
            throw error
        }
    }

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

    public func authorizeHostKey(_ challenge: SSHHostKeyChallenge) async -> SSHHostKeyDecision {
        return await hostKeyAuthorization.authorize(challenge) { [weak self] request in
            self?.waitForHostKey(request.prompt, hostID: request.hostID)
        }
    }

    public func waitForHostKey(_ prompt: SSHHostKeyPrompt, hostID: Host.ID) {
        reconnect.pauseForUserInteraction()
        journey.waitForHostKey(at: hostID, fingerprint: prompt.observation.fingerprint)
    }

    public func progressHandler(
        attemptID: UUID
    ) -> SSHRouteProgressHandler {
        progressHandler(attemptID: attemptID) { [weak self] in self?.connectionAttemptID == $0 }
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
        hostKeyAuthorization.cancelPending()
    }
}
