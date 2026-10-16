import Foundation

/// Queue-confined activation intent. Runtime polling must not repeatedly claim the window.
nonisolated struct SSHPTYActivationState {
    struct Request: Equatable, Sendable {
        let revision: UUID
        let client: RemoteTmuxClientIdentity
    }

    private(set) var isActive = false
    private(set) var client: RemoteTmuxClientIdentity?
    private var revision = UUID()
    private var pending = false
    private var inFlight: Request?

    mutating func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        invalidate(retry: active)
    }

    mutating func updateClient(_ client: RemoteTmuxClientIdentity?) {
        guard self.client != client else { return }
        self.client = client
        invalidate(retry: isActive)
    }

    mutating func viewportChanged() {
        guard pending || inFlight != nil else { return }
        invalidate(retry: isActive)
    }

    mutating func noteInput() {
        // Real input already activates tmux; never let an older control operation follow it.
        invalidate(retry: false)
    }

    mutating func takeRequest(resizeIsSynchronized: Bool) -> Request? {
        guard pending, isActive, let client, resizeIsSynchronized else { return nil }
        let request = Request(revision: revision, client: client)
        pending = false
        inFlight = request
        return request
    }

    func isCurrent(_ request: Request) -> Bool {
        isActive && request.revision == revision && request.client == client && inFlight == request
    }

    mutating func finish(_ request: Request) {
        if inFlight == request { inFlight = nil }
    }

    mutating func reset() {
        self = Self()
    }

    private mutating func invalidate(retry: Bool) {
        revision = UUID()
        pending = retry
        inFlight = nil
    }
}
