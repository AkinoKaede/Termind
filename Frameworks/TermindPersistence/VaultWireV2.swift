import Foundation
import TermindDomain

/// V2 is host-only. Reuses the frozen V1 fields without changing their encoding.
nonisolated enum VaultWireV2 {
    struct Host: Codable {
        var base: VaultWireV1.Host
        var agentForwardingEnabled: Bool
        enum CodingKeys: String, CodingKey { case agentForwardingEnabled }
        init(_ value: TermindDomain.Host) throws {
            var legacy = value
            legacy.agentForwardingEnabled = false
            try VaultWireV1.validateRepresentable(.host(legacy))
            base = VaultWireV1.Host(legacy)
            agentForwardingEnabled = value.agentForwardingEnabled
        }
        init(from decoder: any Decoder) throws {
            base = try VaultWireV1.Host(from: decoder)
            agentForwardingEnabled = try decoder.container(keyedBy: CodingKeys.self).decode(
                Bool.self, forKey: .agentForwardingEnabled)
        }
        func encode(to encoder: any Encoder) throws {
            try base.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(agentForwardingEnabled, forKey: .agentForwardingEnabled)
        }
        var domainValue: TermindDomain.Host {
            var value = base.domainValue
            value.agentForwardingEnabled = agentForwardingEnabled
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
            formatVersion = 2
            key = envelope.key
            version = envelope.version
            isDeleted = envelope.isDeleted
            if case .host(let host) = envelope.payload {
                payload = .host(try Host(host))
            } else if envelope.payload == nil {
                payload = nil
            } else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        var domainValue: VaultEnvelope {
            var value: VaultRecordPayload?
            if case .host(let host) = payload { value = .host(host.domainValue) }
            return VaultEnvelope(
                key: key, version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
        }
    }
}
