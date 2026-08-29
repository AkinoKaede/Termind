import Foundation

nonisolated enum KeyStorage: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case thisDevice
    case iCloud
    case secureEnclave

    var id: String { rawValue }

}

nonisolated enum SSHKeyAlgorithm: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case ed25519 = "ssh-ed25519"
    case ecdsa256 = "ecdsa-sha2-nistp256"
    case ecdsa384 = "ecdsa-sha2-nistp384"
    case ecdsa521 = "ecdsa-sha2-nistp521"
    case rsa = "ssh-rsa"

    nonisolated var id: Self { self }
}

nonisolated struct SSHKeyRef: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
    var algorithm: SSHKeyAlgorithm = .ed25519
    var publicKey: String = ""
    var certificate: String = ""
    var fingerprint: String = ""
    var credentialRef: String = ""
    var storage: KeyStorage = .iCloud
    var keySize: Int?
    var hasPassphrase = false
    var requiresUserPresence = false
    var createdAt: Date = Date(timeIntervalSince1970: 0)
    var colorTag: TagColor = .none
    var sortIndex: Double = 0

    var requiresPassphraseEntry: Bool { hasPassphrase }
}

nonisolated extension SSHKeyRef {
    private enum CodingKeys: String, CodingKey {
        case id, label, algorithm, publicKey, certificate, fingerprint
        case credentialRef, storage, keySize, hasPassphrase, requiresUserPresence
        case createdAt, colorTag, sortIndex
    }

    /// Vault records written before key colors existed do not contain
    /// `colorTag`. Treating that absence as `.none` keeps those records valid
    /// while preserving synthesized encoding for new records.
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
            keySize: try container.decodeIfPresent(Int.self, forKey: .keySize),
            hasPassphrase: try container.decode(Bool.self, forKey: .hasPassphrase),
            requiresUserPresence: try container.decode(Bool.self, forKey: .requiresUserPresence),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            colorTag: (try? container.decode(TagColor.self, forKey: .colorTag)) ?? .none,
            sortIndex: try container.decode(Double.self, forKey: .sortIndex)
        )
    }
}
