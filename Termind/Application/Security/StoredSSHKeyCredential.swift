import Foundation

nonisolated struct SecureEnclaveKeyCredential: Codable, Hashable, Sendable {
    var dataRepresentation: Data
}

nonisolated enum StoredSSHKeyCredential: Hashable, Sendable {
    case software(SSHPrivateKeySecret)
    case secureEnclave(SecureEnclaveKeyCredential)
}

nonisolated struct SecureEnclaveKeyMaterial: Sendable {
    var credential: SecureEnclaveKeyCredential
    var publicKey: String
    var fingerprint: String
}
