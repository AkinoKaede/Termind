// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

/// Keeps the built-in MCP server credential on this Mac, independently of AI
/// provider and remote MCP client credential sync.
nonisolated struct MCPServerTokenStore: Sendable {
    static let reference = "termind.ai.mcpserver.token"

    private let secrets: any SecretStoring

    init(secrets: any SecretStoring) {
        self.secrets = secrets
    }

    /// Moves the value written by older releases out of iCloud Keychain.
    ///
    /// A local value always wins when both locations contain a token. When only
    /// the synchronized copy exists, it is verified locally before that source
    /// is removed. A failed copy or delete is safe to retry on the next read.
    func load() throws -> String? {
        let local = try secrets.string(for: Self.reference, storage: .thisDevice)
        guard let synchronized = try secrets.string(for: Self.reference, storage: .iCloud) else {
            return local
        }

        let value: String
        if let local {
            value = local
        } else {
            try secrets.setString(synchronized, for: Self.reference, storage: .thisDevice)
            guard try secrets.string(for: Self.reference, storage: .thisDevice) == synchronized else {
                throw CocoaError(.coderInvalidValue)
            }
            value = synchronized
        }

        try secrets.setString(nil, for: Self.reference, storage: .iCloud)
        return value
    }

    func save(_ value: String) throws {
        let previous = try load()
        do {
            try secrets.setString(value, for: Self.reference, storage: .thisDevice)
            guard try secrets.string(for: Self.reference, storage: .thisDevice) == value else {
                throw CocoaError(.coderInvalidValue)
            }
        } catch {
            try? secrets.setString(previous, for: Self.reference, storage: .thisDevice)
            throw error
        }
    }
}
