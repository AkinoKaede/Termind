// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// V4 adds backend-neutral session persistence without allowing older writers to erase it.
nonisolated enum VaultWireV4 {
    struct Host: Codable {
        var base: VaultWireV2.Host
        var sessionPersistence: SessionPersistencePreferences

        init(_ value: TermindDomain.Host) throws {
            var legacy = value
            legacy.sessionPersistence = .init(enabled: false)
            base = try VaultWireV2.Host(legacy)
            sessionPersistence = value.sessionPersistence
        }

        var domainValue: TermindDomain.Host {
            var value = base.domainValue
            value.sessionPersistence = sessionPersistence
            return value
        }
    }

    struct HostGroup: Codable {
        var base: VaultWireV3.HostGroup
        var sessionPersistence: [String: SessionPersistencePreferences]

        init(_ value: TermindDomain.HostGroup) {
            base = VaultWireV3.HostGroup(value)
            sessionPersistence = Dictionary(
                uniqueKeysWithValues: (value.tailscale?.hostPreferences ?? [:]).map {
                    ($0.key.uuidString.lowercased(), $0.value.sessionPersistence)
                })
        }

        private enum CodingKeys: String, CodingKey { case base, sessionPersistence }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            base = try values.decode(VaultWireV3.HostGroup.self, forKey: .base)
            sessionPersistence = try values.decode(
                [String: SessionPersistencePreferences].self, forKey: .sessionPersistence)
            guard
                sessionPersistence.keys.allSatisfy({
                    UUID(uuidString: $0)?.uuidString.lowercased() == $0
                        && base.tailscale?.hostPreferences[$0] != nil
                })
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionPersistence, in: values, debugDescription: "Invalid host identifier")
            }
        }

        var domainValue: TermindDomain.HostGroup {
            var value = base.domainValue
            for (key, preferences) in sessionPersistence {
                if let id = UUID(uuidString: key), value.tailscale?.hostPreferences[id] != nil {
                    value.tailscale?.hostPreferences[id]?.sessionPersistence = preferences
                }
            }
            return value
        }
    }

    enum Payload: Codable {
        case host(Host)
        case hostGroup(HostGroup)
    }

    struct Envelope: Codable {
        var formatVersion: Int
        var key: VaultRecordKey
        var version: VaultVersion
        var isDeleted: Bool
        var payload: Payload?

        init(_ envelope: VaultEnvelope) throws {
            guard [.host, .hostGroup].contains(envelope.key.kind) else { throw CocoaError(.coderInvalidValue) }
            formatVersion = 4
            key = envelope.key
            version = envelope.version
            isDeleted = envelope.isDeleted
            switch envelope.payload {
            case .host(let host): payload = .host(try Host(host))
            case .hostGroup(let group): payload = .hostGroup(HostGroup(group))
            case nil: payload = nil
            default: throw CocoaError(.coderInvalidValue)
            }
        }

        var domainValue: VaultEnvelope {
            let value: VaultRecordPayload?
            switch payload {
            case .host(let host): value = .host(host.domainValue)
            case .hostGroup(let group): value = .hostGroup(group.domainValue)
            case nil: value = nil
            }
            return VaultEnvelope(
                key: key, version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
        }
    }
}
