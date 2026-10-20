// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// How a feature maps admitted work onto authenticated SSH connections.
///
/// Single-channel features do not use this type: they own their channel
/// directly and therefore have nothing to schedule.
public nonisolated enum SSHChannelSchedulingMode: Hashable, Sendable {
    /// Keep one authenticated connection and multiplex every admitted operation
    /// as its own channel.
    case channelsOnly

    /// Prefer another authenticated connection for overlap. If a silent
    /// additional connection cannot be opened, keep the same admission limit
    /// and map those leases to sibling channels on the primary connection.
    case connectionsPreferred
}
