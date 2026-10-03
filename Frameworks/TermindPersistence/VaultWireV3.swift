import Foundation
import TermindDomain

/// Group-scoped Tailscale host identities require an explicit V3 wire contract.
nonisolated enum VaultWireV3 {
    struct HostGroup: Codable {
        var base: VaultWireV1.HostGroup
        var tailscale: TailscaleGroupConfiguration?

        enum CodingKeys: String, CodingKey { case tailscale }
        enum TailscaleKeys: String, CodingKey { case hostIdentityVersion }

        init(_ value: TermindDomain.HostGroup) {
            base = VaultWireV1.HostGroup(value)
            tailscale = value.tailscale
        }

        init(from decoder: any Decoder) throws {
            base = try VaultWireV1.HostGroup(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tailscale = try values.decode(TailscaleGroupConfiguration?.self, forKey: .tailscale)
            if tailscale != nil {
                // Only local historical JSON may omit this field. Missing it in V3
                // could otherwise silently change every projected host's identity.
                let configuration = try values.nestedContainer(keyedBy: TailscaleKeys.self, forKey: .tailscale)
                _ = try configuration.decode(
                    TailscaleGroupConfiguration.HostIdentityVersion.self, forKey: .hostIdentityVersion)
            }
        }

        func encode(to encoder: any Encoder) throws {
            try base.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(tailscale, forKey: .tailscale)
        }

        var domainValue: TermindDomain.HostGroup {
            var value = base.domainValue
            value.tailscale = tailscale
            return value
        }
    }

    enum Payload: Codable {
        case hostGroup(HostGroup)
    }

    struct Envelope: Codable {
        var formatVersion: Int
        var key: VaultRecordKey
        var version: VaultVersion
        var isDeleted: Bool
        var payload: Payload?

        init(_ envelope: VaultEnvelope) throws {
            guard envelope.key.kind == .hostGroup else { throw CocoaError(.coderInvalidValue) }
            formatVersion = 3
            key = envelope.key
            version = envelope.version
            isDeleted = envelope.isDeleted
            if case .hostGroup(let group) = envelope.payload {
                payload = .hostGroup(HostGroup(group))
            } else if envelope.payload == nil {
                payload = nil
            } else {
                throw CocoaError(.coderInvalidValue)
            }
        }

        var domainValue: VaultEnvelope {
            let value: VaultRecordPayload?
            switch payload {
            case .hostGroup(let group): value = .hostGroup(group.domainValue)
            case nil: value = nil
            }
            return VaultEnvelope(
                key: key, version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
        }
    }
}
