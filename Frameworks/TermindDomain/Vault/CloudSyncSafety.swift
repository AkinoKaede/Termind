// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A CloudKit replica boundary, independent of the app and local database versions.
public nonisolated struct CloudSyncScope: Hashable, Sendable {
    public var container: String
    public var environment: String
    public var account: String
    public var zone: String
    public var owner: String
    public var consumer: String = ""

    public init(container: String, environment: String, account: String, zone: String, owner: String) {
        self.container = container
        self.environment = environment
        self.account = account
        self.zone = zone
        self.owner = owner
    }

    public var storageKey: String {
        let identity = [container, environment, account, zone, owner].map { "\($0.utf8.count):\($0)" }.joined()
        // Empty preserves shipped scope keys. Independent consumers of a shared
        // zone keep separate recovery checkpoints and upload restrictions.
        return consumer.isEmpty ? identity : identity + "\(consumer.utf8.count):\(consumer)"
    }
}

public nonisolated enum CloudSyncQuarantineReason: String, Codable, Sendable {
    case unsupportedFormat
    case invalidRecord
    case unreadablePayload
}

public nonisolated enum CloudSyncCompatibilityError: LocalizedError {
    case unsupportedFormat(Int)
    case unsupportedKind(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            String(localized: "A newer version of Termind is required to edit some of these records.")
        case .unsupportedFormat(let version):
            String(localized: "This iCloud record requires sync format \(version). Update Termind to edit it.")
        }
    }
}
