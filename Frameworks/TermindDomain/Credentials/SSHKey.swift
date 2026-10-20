// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum KeyStorage: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case thisDevice
    case iCloud
    case secureEnclave
    /// Private key material is held by an authenticator outside this device, such as a USB or NFC security key.
    case external

    public var id: String { rawValue }

}

public nonisolated enum SSHKeyAlgorithm: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case unknown
    case securityKey = "sk-ecdsa-sha2-nistp256@openssh.com"
    case ed25519 = "ssh-ed25519"
    case ecdsa256 = "ecdsa-sha2-nistp256"
    case ecdsa384 = "ecdsa-sha2-nistp384"
    case ecdsa521 = "ecdsa-sha2-nistp521"
    case rsa = "ssh-rsa"

    public nonisolated var id: Self { self }
}

public nonisolated struct SSHKeyRef: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var label: String
    public var algorithm: SSHKeyAlgorithm = .ed25519
    public var publicKey: String = ""
    public var certificate: String = ""
    public var fingerprint: String = ""
    public var securityKey: SecurityKeyCredential?
    public var credentialRef: String = ""
    public var storage: KeyStorage = .iCloud
    public var keySize: Int?
    public var hasPassphrase = false
    public var requiresUserPresence = false
    public var createdAt: Date = Date(timeIntervalSince1970: 0)
    public var colorTag: TagColor = .none
    public var sortIndex: Double = 0

    public var requiresPassphraseEntry: Bool { hasPassphrase }
    public init(
        id: UUID = UUID(), label: String, algorithm: SSHKeyAlgorithm = .ed25519, publicKey: String = "",
        certificate: String = "", fingerprint: String = "", credentialRef: String = "", storage: KeyStorage = .iCloud,
        securityKey: SecurityKeyCredential? = nil, keySize: Int? = nil, hasPassphrase: Bool = false,
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

}

nonisolated extension SSHKeyRef {
    private enum CodingKeys: String, CodingKey {
        case id, label, algorithm, publicKey, certificate, fingerprint
        case securityKey, credentialRef, storage, keySize, hasPassphrase, requiresUserPresence
        case createdAt, colorTag, sortIndex
    }

    /// Vault records written before key colors existed do not contain
    /// `colorTag`. Treating that absence as `.none` keeps those records valid
    /// while preserving synthesized encoding for new records.
    public init(from decoder: any Decoder) throws {
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
            securityKey: try container.decodeIfPresent(SecurityKeyCredential.self, forKey: .securityKey),
            keySize: try container.decodeIfPresent(Int.self, forKey: .keySize),
            hasPassphrase: try container.decode(Bool.self, forKey: .hasPassphrase),
            requiresUserPresence: try container.decode(Bool.self, forKey: .requiresUserPresence),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            colorTag: (try? container.decode(TagColor.self, forKey: .colorTag)) ?? .none,
            sortIndex: try container.decode(Double.self, forKey: .sortIndex)
        )
        if algorithm == .securityKey { storage = .external }
    }
}
