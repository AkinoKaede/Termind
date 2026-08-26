import Foundation

nonisolated enum KeyStorage: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case thisDevice
    case iCloudKeychain
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

nonisolated struct SSHKeyRef: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
    var algorithm: SSHKeyAlgorithm = .ed25519
    var publicKey: String = ""
    var certificate: String = ""
    var fingerprint: String = ""
    var credentialRef: String = ""
    var storage: KeyStorage = .iCloudKeychain
    var keySize: Int?
    var hasPassphrase = false
    var storesPassphrase = false
    var requiresUserPresence = false
    var createdAt: Date = Date(timeIntervalSince1970: 0)
    var sortIndex: Double = 0

    var requiresPassphraseEntry: Bool { hasPassphrase && !storesPassphrase }
}

