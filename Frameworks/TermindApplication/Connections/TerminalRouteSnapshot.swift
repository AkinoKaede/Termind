import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Last-established data-route progress, independent of SSH bootstrap and protocol readiness.
public nonisolated struct TerminalRouteSnapshot: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case opening
        case ready
        case unavailable
    }

    public let attemptID: UUID
    public let revision: UInt64
    public let stage: Stage
    public let establishedHostIDs: [Host.ID]
    public let activeHostID: Host.ID?
    public let event: SSHRouteEvent?

    public init(
        attemptID: UUID, revision: UInt64, stage: Stage,
        establishedHostIDs: [Host.ID] = [], activeHostID: Host.ID? = nil,
        event: SSHRouteEvent? = nil
    ) {
        self.attemptID = attemptID
        self.revision = revision
        self.stage = stage
        self.establishedHostIDs = establishedHostIDs
        self.activeHostID = activeHostID
        self.event = event
    }
}
