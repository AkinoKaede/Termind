import Foundation
import TermindDomain

/// V7 protects Wake-on-LAN preferences from older sync writers.
nonisolated enum VaultWireV7 {
    struct Host: Codable {
        var base: VaultWireV6.Host
        var wakeOnLAN: WakeOnLANPreferences

        init(_ value: TermindDomain.Host) throws {
            base = try VaultWireV6.Host(value)
            wakeOnLAN = value.wakeOnLAN
        }

        var domainValue: TermindDomain.Host {
            var value = base.domainValue
            value.wakeOnLAN = wakeOnLAN
            return value
        }
    }

    struct HostGroup: Codable {
        var base: VaultWireV6.HostGroup
        var wakeOnLAN: [String: WakeOnLANPreferences]

        init(_ value: TermindDomain.HostGroup) {
            base = VaultWireV6.HostGroup(value)
            wakeOnLAN = Dictionary(
                uniqueKeysWithValues: (value.tailscale?.hostPreferences ?? [:]).map {
                    ($0.key.uuidString.lowercased(), $0.value.wakeOnLAN)
                })
        }

        private enum CodingKeys: String, CodingKey { case base, wakeOnLAN }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            base = try values.decode(VaultWireV6.HostGroup.self, forKey: .base)
            wakeOnLAN = try values.decode([String: WakeOnLANPreferences].self, forKey: .wakeOnLAN)
            let validPeerIDs = Set((base.domainValue.tailscale?.hostPreferences ?? [:]).keys)
            guard
                wakeOnLAN.keys.allSatisfy({ key in
                    guard let id = UUID(uuidString: key), id.uuidString.lowercased() == key else { return false }
                    return validPeerIDs.contains(id)
                })
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .wakeOnLAN, in: values, debugDescription: "Invalid host identifier")
            }
        }

        var domainValue: TermindDomain.HostGroup {
            var value = base.domainValue
            for (key, preferences) in wakeOnLAN {
                if let id = UUID(uuidString: key) {
                    value.tailscale?.hostPreferences[id]?.wakeOnLAN = preferences
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
            formatVersion = 7
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
