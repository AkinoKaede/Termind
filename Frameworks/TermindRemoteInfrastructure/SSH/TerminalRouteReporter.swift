import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// Route ownership facts, independent of the ET protocol's connection and suspension state.
/// The bridge serializes its callbacks; the lock also covers the initial open and engine close.
nonisolated final class TerminalRouteReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let hostIDs: [Host.ID]
    private let changed: @Sendable (TerminalRouteSnapshot) -> Void
    private var attemptID: UUID?
    private var revision: UInt64 = 0
    private var stage: TerminalRouteSnapshot.Stage = .unavailable
    private var establishedCount = 0
    private var closed = false

    init(hostIDs: [Host.ID], changed: @escaping @Sendable (TerminalRouteSnapshot) -> Void) {
        self.hostIDs = hostIDs
        self.changed = changed
    }

    func begin() -> UUID {
        let id = UUID()
        let snapshot = lock.withLock { () -> TerminalRouteSnapshot? in
            guard !closed else { return nil }
            attemptID = id
            stage = .opening
            establishedCount = 0
            return makeSnapshot(activeHostID: hostIDs.first)
        }
        if let snapshot { changed(snapshot) }
        return id
    }

    func receive(_ event: SSHRouteEvent, attemptID: UUID) {
        let snapshot = lock.withLock { () -> TerminalRouteSnapshot? in
            guard !closed, self.attemptID == attemptID, stage == .opening else { return nil }
            let hostID: Host.ID
            let establishes: Bool
            switch event {
            case .authenticated(let id), .connected(let id):
                hostID = id
                establishes = true
            case .proxyConnecting(let id), .proxyConnected(let id), .connecting(let id), .authenticating(let id),
                .initializing(let id, _):
                hostID = id
                establishes = false
            }
            // Never infer an earlier hop from a later callback. Only the ordered prefix is established.
            guard hostIDs.firstIndex(of: hostID) == establishedCount else { return nil }
            if establishes { establishedCount += 1 }
            let active = establishedCount < hostIDs.count ? hostIDs[establishedCount] : nil
            return makeSnapshot(activeHostID: active, event: event)
        }
        if let snapshot { changed(snapshot) }
    }

    func ready(attemptID: UUID) {
        let snapshot = lock.withLock { () -> TerminalRouteSnapshot? in
            guard !closed, self.attemptID == attemptID, stage == .opening else { return nil }
            stage = .ready
            establishedCount = hostIDs.count
            return makeSnapshot()
        }
        if let snapshot { changed(snapshot) }
    }

    func retire(attemptID: UUID) {
        let snapshot = lock.withLock { () -> TerminalRouteSnapshot? in
            guard !closed, self.attemptID == attemptID, stage != .unavailable else { return nil }
            stage = .unavailable
            establishedCount = 0
            return makeSnapshot()
        }
        if let snapshot { changed(snapshot) }
    }

    func close() {
        let snapshot = lock.withLock { () -> TerminalRouteSnapshot? in
            guard !closed else { return nil }
            closed = true
            guard attemptID != nil, stage != .unavailable else { return nil }
            stage = .unavailable
            establishedCount = 0
            return makeSnapshot()
        }
        if let snapshot { changed(snapshot) }
    }

    private func makeSnapshot(activeHostID: Host.ID? = nil, event: SSHRouteEvent? = nil) -> TerminalRouteSnapshot {
        revision += 1
        return TerminalRouteSnapshot(
            attemptID: attemptID!, revision: revision, stage: stage,
            establishedHostIDs: Array(hostIDs.prefix(establishedCount)), activeHostID: activeHostID, event: event)
    }
}
