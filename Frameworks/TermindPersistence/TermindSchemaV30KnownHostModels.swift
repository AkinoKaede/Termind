// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

/// V30 removes the historical host-key mismatch marker while preserving Known Host trust records.
public enum TermindSchemaV30KnownHostModels {
    @Model
    public final class PersistentKnownHost {
        @Attribute(.unique) public var id: UUID = UUID()
        public var hostname = ""
        public var port = 22
        public var algorithm = SSHKeyAlgorithm.ed25519.rawValue
        public var fingerprint = ""
        public var addedAt = Date(timeIntervalSince1970: 0)

        public init(_ value: KnownHostEntry) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: KnownHostEntry) {
            hostname = value.hostname
            port = value.port
            algorithm = value.algorithm.rawValue
            fingerprint = value.fingerprint
            addedAt = value.addedAt
        }

        public var value: KnownHostEntry {
            KnownHostEntry(
                id: id, hostname: hostname, port: port,
                algorithm: SSHKeyAlgorithm(rawValue: algorithm) ?? .ed25519,
                fingerprint: fingerprint, addedAt: addedAt
            )
        }
    }
}
