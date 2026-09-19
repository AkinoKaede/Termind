import Foundation

/// How a feature maps admitted work onto authenticated SSH transports.
///
/// Single-Channel features do not use this type: they own their Channel
/// directly and therefore have nothing to schedule.
public nonisolated enum SSHChannelSchedulingMode: Hashable, Sendable {
    /// Keep one authenticated transport and multiplex every admitted operation
    /// as its own Channel.
    case channelsOnly

    /// Prefer another authenticated connection for overlap. If a silent
    /// additional connection cannot be opened, keep the same admission limit
    /// and map those leases to sibling Channels on the primary transport.
    case connectionsPreferred
}
