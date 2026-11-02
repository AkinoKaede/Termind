// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Credential storage currently prevents reading a saved reference.
/// Keep this separate from missing credentials and server authentication failures.
public nonisolated struct SSHCredentialAccessUnavailable: LocalizedError, Sendable, Equatable {
    public var hostID: UUID?

    public init(hostID: UUID? = nil) {
        self.hostID = hostID
    }

    public func at(_ hostID: UUID) -> Self {
        Self(hostID: self.hostID ?? hostID)
    }

    public var errorDescription: String? {
        String(localized: "Saved credentials are temporarily unavailable.")
    }
}
