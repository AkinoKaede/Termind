// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// V8 preserves creation order independently of the editable display order.
nonisolated enum VaultWireV8 {
    struct Host: Codable {
        var base: VaultWireV7.Host
        var createdAt: Date?

        init(_ value: TermindDomain.Host) throws {
            base = try VaultWireV7.Host(value)
            createdAt = value.createdAt
        }

        var domainValue: TermindDomain.Host {
            var value = base.domainValue
            value.createdAt = createdAt
            return value
        }
    }

    enum Payload: Codable { case host(Host) }

    struct Envelope: Codable {
        var formatVersion: Int
        var key: VaultRecordKey
        var version: VaultVersion
        var isDeleted: Bool
        var payload: Payload?

        init(_ envelope: VaultEnvelope) throws {
            guard envelope.key.kind == .host else { throw CocoaError(.coderInvalidValue) }
            formatVersion = 8
            key = envelope.key
            version = envelope.version
            isDeleted = envelope.isDeleted
            switch envelope.payload {
            case .host(let host): payload = .host(try Host(host))
            case nil: payload = nil
            default: throw CocoaError(.coderInvalidValue)
            }
        }

        var domainValue: VaultEnvelope {
            let value: VaultRecordPayload?
            switch payload {
            case .host(let host): value = .host(host.domainValue)
            case nil: value = nil
            }
            return VaultEnvelope(
                key: key, version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
        }
    }
}
