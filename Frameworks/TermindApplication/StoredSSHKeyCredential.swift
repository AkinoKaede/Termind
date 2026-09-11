import Foundation

public nonisolated struct SecureEnclaveKeyCredential: Codable, Hashable, Sendable {
    public var dataRepresentation: Data
    public init(dataRepresentation: Data) {
        self.dataRepresentation = dataRepresentation
    }

}

public nonisolated enum StoredSSHKeyCredential: Hashable, Sendable {
    case software(SSHPrivateKeySecret)
    case secureEnclave(SecureEnclaveKeyCredential)
}

public nonisolated struct SecureEnclaveKeyMaterial: Sendable {
    public var credential: SecureEnclaveKeyCredential
    public var publicKey: String
    public var fingerprint: String
    public init(credential: SecureEnclaveKeyCredential, publicKey: String, fingerprint: String) {
        self.credential = credential
        self.publicKey = publicKey
        self.fingerprint = fingerprint
    }

}
