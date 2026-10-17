import Foundation
import TermindDomain

/// V6 protects terminal transport preferences from older sync writers.
nonisolated enum VaultWireV6 {
    struct Host: Codable {
        var base: VaultWireV5.Host
        var terminalTransports: HostTerminalTransports

        init(_ value: TermindDomain.Host) throws {
            base = try VaultWireV5.Host(value)
            terminalTransports = value.terminalTransports
        }

        var domainValue: TermindDomain.Host {
            var value = base.domainValue
            value.terminalTransports = terminalTransports
            return value
        }
    }

    struct HostGroup: Codable {
        var base: VaultWireV5.HostGroup
        var terminalTransports: [String: HostTerminalTransports]

        init(_ value: TermindDomain.HostGroup) {
            base = VaultWireV5.HostGroup(value)
            terminalTransports = Dictionary(
                uniqueKeysWithValues: (value.tailscale?.hostPreferences ?? [:]).map {
                    ($0.key.uuidString.lowercased(), $0.value.terminalTransports)
                })
        }

        private enum CodingKeys: String, CodingKey { case base, terminalTransports }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            base = try values.decode(VaultWireV5.HostGroup.self, forKey: .base)
            terminalTransports = try values.decode([String: HostTerminalTransports].self, forKey: .terminalTransports)
            let validPeerIDs = Set((base.domainValue.tailscale?.hostPreferences ?? [:]).keys)
            guard
                terminalTransports.keys.allSatisfy({ key in
                    guard let id = UUID(uuidString: key), id.uuidString.lowercased() == key else { return false }
                    return validPeerIDs.contains(id)
                })
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .terminalTransports, in: values, debugDescription: "Invalid host identifier")
            }
        }

        var domainValue: TermindDomain.HostGroup {
            var value = base.domainValue
            for (key, transports) in terminalTransports {
                if let id = UUID(uuidString: key) {
                    value.tailscale?.hostPreferences[id]?.terminalTransports = transports
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
            formatVersion = 6
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
