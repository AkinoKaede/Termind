import Foundation
import TermindDomain

/// V5 keeps user-selected artwork separate from system-detected metadata.
nonisolated enum VaultWireV5 {
    struct Host: Codable {
        var base: VaultWireV4.Host
        var iconOverrideID: String?

        init(_ value: TermindDomain.Host) throws {
            base = try VaultWireV4.Host(value)
            iconOverrideID = value.iconOverrideID
        }

        var domainValue: TermindDomain.Host {
            var value = base.domainValue
            value.iconOverrideID = iconOverrideID
            return value
        }
    }

    struct HostGroup: Codable {
        var base: VaultWireV4.HostGroup
        var iconOverrides: [String: String]

        init(_ value: TermindDomain.HostGroup) {
            base = VaultWireV4.HostGroup(value)
            iconOverrides = Dictionary(
                uniqueKeysWithValues: (value.tailscale?.hostPreferences ?? [:]).compactMap { id, preferences in
                    preferences.iconOverrideID.map { (id.uuidString.lowercased(), $0) }
                })
        }

        private enum CodingKeys: String, CodingKey { case base, iconOverrides }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            base = try values.decode(VaultWireV4.HostGroup.self, forKey: .base)
            iconOverrides = try values.decode([String: String].self, forKey: .iconOverrides)
            guard
                iconOverrides.keys.allSatisfy({
                    UUID(uuidString: $0)?.uuidString.lowercased() == $0
                        && base.base.tailscale?.hostPreferences[$0] != nil
                })
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .iconOverrides, in: values, debugDescription: "Invalid host identifier")
            }
        }

        var domainValue: TermindDomain.HostGroup {
            var value = base.domainValue
            for (key, icon) in iconOverrides {
                if let id = UUID(uuidString: key) { value.tailscale?.hostPreferences[id]?.iconOverrideID = icon }
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
            formatVersion = 5
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
