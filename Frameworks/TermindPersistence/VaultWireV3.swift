import Foundation
import TermindDomain

/// V3 preserves group-scoped Tailscale identities and keys whose algorithm is not yet known.
nonisolated enum VaultWireV3 {
    struct HostGroup: Codable {
        var base: VaultWireV1.HostGroup
        var tailscale: TailscaleGroupConfiguration?

        enum CodingKeys: String, CodingKey { case tailscale }

        init(_ value: TermindDomain.HostGroup) {
            base = VaultWireV1.HostGroup(value)
            tailscale = value.tailscale
        }

        init(from decoder: any Decoder) throws {
            base = try VaultWireV1.HostGroup(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tailscale = try values.decode(TailscaleGroupConfiguration?.self, forKey: .tailscale)
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

    typealias KeyStorage = VaultWireV1.KeyStorage
    typealias TagColor = VaultWireV1.TagColor
    enum SSHKeyAlgorithm: String, Codable {
        case unknown
        case securityKey = "sk-ecdsa-sha2-nistp256@openssh.com"
        case ed25519 = "ssh-ed25519"
        case ecdsa256 = "ecdsa-sha2-nistp256"
        case ecdsa384 = "ecdsa-sha2-nistp384"
        case ecdsa521 = "ecdsa-sha2-nistp521"
        case rsa = "ssh-rsa"
    }
    struct SecurityKeyReference: Codable {
        enum Verification: String, Codable { case required, preferred, discouraged }
        var credentialID: Data
        var publicKeyX963: Data
        var userVerification: Verification
        var requiresUserPresence: Bool
        init(_ value: TermindDomain.SecurityKeyCredential) {
            credentialID = value.credentialID
            publicKeyX963 = value.publicKeyX963
            userVerification = Verification(rawValue: value.userVerification.rawValue)!
            requiresUserPresence = value.requiresUserPresence
        }
        var domainValue: TermindDomain.SecurityKeyCredential {
            TermindDomain.SecurityKeyCredential(
                credentialID: credentialID, publicKeyX963: publicKeyX963,
                userVerification: .init(rawValue: userVerification.rawValue)!,
                requiresUserPresence: requiresUserPresence)
        }
    }
    struct SSHKeyRef: Codable, Identifiable {
        var id: UUID = UUID()
        var label: String
        var algorithm: SSHKeyAlgorithm = .ed25519
        var publicKey: String = ""
        var certificate: String = ""
        var fingerprint: String = ""
        var securityKey: SecurityKeyReference?
        var credentialRef: String = ""
        var storage: KeyStorage = .iCloud
        var keySize: Int?
        var hasPassphrase = false
        var requiresUserPresence = false
        var createdAt: Date = Date(timeIntervalSince1970: 0)
        var colorTag: TagColor = .none
        var sortIndex: Double = 0
        init(
            id: UUID = UUID(), label: String, algorithm: SSHKeyAlgorithm = .ed25519, publicKey: String = "",
            certificate: String = "", fingerprint: String = "", credentialRef: String = "",
            storage: KeyStorage = .iCloud,
            securityKey: SecurityKeyReference? = nil, keySize: Int? = nil, hasPassphrase: Bool = false,
            requiresUserPresence: Bool = false,
            createdAt: Date = Date(timeIntervalSince1970: 0), colorTag: TagColor = .none, sortIndex: Double = 0
        ) {
            self.id = id
            self.label = label
            self.algorithm = algorithm
            self.publicKey = publicKey
            self.certificate = certificate
            self.fingerprint = fingerprint
            self.securityKey = securityKey
            self.credentialRef = credentialRef
            self.storage = storage
            self.keySize = keySize
            self.hasPassphrase = hasPassphrase
            self.requiresUserPresence = requiresUserPresence
            self.createdAt = createdAt
            self.colorTag = colorTag
            self.sortIndex = sortIndex
        }
        private enum CodingKeys: String, CodingKey {
            case id, label, algorithm, publicKey, certificate, fingerprint
            case securityKey, credentialRef, storage, keySize, hasPassphrase, requiresUserPresence
            case createdAt, colorTag, sortIndex
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decode(UUID.self, forKey: .id),
                label: try container.decode(String.self, forKey: .label),
                algorithm: try container.decode(SSHKeyAlgorithm.self, forKey: .algorithm),
                publicKey: try container.decode(String.self, forKey: .publicKey),
                certificate: try container.decode(String.self, forKey: .certificate),
                fingerprint: try container.decode(String.self, forKey: .fingerprint),
                credentialRef: try container.decode(String.self, forKey: .credentialRef),
                storage: try container.decode(KeyStorage.self, forKey: .storage),
                securityKey: try container.decodeIfPresent(SecurityKeyReference.self, forKey: .securityKey),
                keySize: try container.decodeIfPresent(Int.self, forKey: .keySize),
                hasPassphrase: try container.decode(Bool.self, forKey: .hasPassphrase),
                requiresUserPresence: try container.decode(Bool.self, forKey: .requiresUserPresence),
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                colorTag: (try? container.decode(TagColor.self, forKey: .colorTag)) ?? .none,
                sortIndex: try container.decode(Double.self, forKey: .sortIndex)
            )
        }
        init(_ value: TermindDomain.SSHKeyRef) {
            self.securityKey = value.securityKey.map(SecurityKeyReference.init)
            self.id = value.id
            self.label = value.label
            self.algorithm = SSHKeyAlgorithm(rawValue: value.algorithm.rawValue)!
            self.publicKey = value.publicKey
            self.certificate = value.certificate
            self.fingerprint = value.fingerprint
            self.credentialRef = value.credentialRef
            // Retain the existing external-authenticator storage representation.
            self.storage = value.storage == .external ? .thisDevice : KeyStorage(rawValue: value.storage.rawValue)!
            self.keySize = value.keySize
            self.hasPassphrase = value.hasPassphrase
            self.requiresUserPresence = value.requiresUserPresence
            self.createdAt = value.createdAt
            self.colorTag = TagColor(rawValue: value.colorTag.rawValue)!
            self.sortIndex = value.sortIndex
        }
        var domainValue: TermindDomain.SSHKeyRef {
            var result = TermindDomain.SSHKeyRef(label: "")
            result.securityKey = securityKey?.domainValue
            result.id = id
            result.label = label
            result.algorithm = TermindDomain.SSHKeyAlgorithm(rawValue: algorithm.rawValue)!
            result.publicKey = publicKey
            result.certificate = certificate
            result.fingerprint = fingerprint
            result.credentialRef = credentialRef
            result.storage =
                algorithm == .securityKey ? .external : TermindDomain.KeyStorage(rawValue: storage.rawValue)!
            result.keySize = keySize
            result.hasPassphrase = hasPassphrase
            result.requiresUserPresence = requiresUserPresence
            result.createdAt = createdAt
            result.colorTag = TermindDomain.TagColor(rawValue: colorTag.rawValue)!
            result.sortIndex = sortIndex
            return result
        }
    }
    enum Payload: Codable {
        case sshKey(SSHKeyRef)
        case hostGroup(HostGroup)
    }

    struct Envelope: Codable {
        var formatVersion: Int
        var key: VaultRecordKey
        var version: VaultVersion
        var isDeleted: Bool
        var payload: Payload?

        init(_ envelope: VaultEnvelope) throws {
            guard [.hostGroup, .sshKey].contains(envelope.key.kind) else { throw CocoaError(.coderInvalidValue) }
            formatVersion = 3
            key = envelope.key
            version = envelope.version
            isDeleted = envelope.isDeleted
            if case .sshKey(let key) = envelope.payload {
                guard key.storage != .external || key.algorithm == .securityKey else {
                    throw CocoaError(.coderInvalidValue)
                }
                payload = .sshKey(SSHKeyRef(key))
            } else if case .hostGroup(let group) = envelope.payload {
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
            case .sshKey(let key): value = .sshKey(key.domainValue)
            case .hostGroup(let group): value = .hostGroup(group.domainValue)
            case nil: value = nil
            }
            return VaultEnvelope(
                key: key, version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
        }
    }
}
