// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum TerminalTransportError: LocalizedError, Sendable {
    case invalidCheckpoint, unsupportedRoute, bootstrapFailed, unreachable, sessionFailed, suspended
    public var errorDescription: String? {
        switch self {
        case .invalidCheckpoint:
            String(localized: "The saved terminal session cannot be restored.")
        case .unsupportedRoute:
            String(localized: "This terminal transport is unavailable for this connection.")
        case .bootstrapFailed:
            String(localized: "Unable to start the terminal server. Check that it is installed on the host.")
        case .unreachable:
            String(localized: "The terminal server did not respond. Check the transport port and firewall.")
        case .sessionFailed:
            String(localized: "The terminal session cannot continue. Open a new session to connect again.")
        case .suspended:
            String(localized: "The terminal session is suspended.")
        }
    }
}
