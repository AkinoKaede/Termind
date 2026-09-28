import Foundation
import SwiftData
import TermindDomain

public enum TermindSchemaV45KeyModels {
    @Model
    public final class PersistentSSHKey {
        @Attribute(.unique) public var id: UUID = UUID()
        public var label = ""
        public var algorithm = SSHKeyAlgorithm.ed25519.rawValue
        public var publicKey = ""
        public var certificate = ""
        public var fingerprint = ""
        public var securityKeyCredentialID: Data?
        public var securityKeyPublicKey: Data?
        public var securityKeyVerification: String?
        public var credentialRef = ""
        public var storage = KeyStorage.iCloud.rawValue
        public var keySize: Int?
        public var hasPassphrase = false
        public var requiresUserPresence = false
        public var createdAt = Date(timeIntervalSince1970: 0)
        public var colorTag = TagColor.none.rawValue
        public var sortIndex = 0.0

        public init(_ value: SSHKeyRef) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: SSHKeyRef) {
            label = value.label
            algorithm = value.algorithm.rawValue
            publicKey = value.publicKey
            certificate = value.certificate
            fingerprint = value.fingerprint
            securityKeyCredentialID = value.securityKey?.credentialID
            securityKeyPublicKey = value.securityKey?.publicKeyX963
            securityKeyVerification = value.securityKey?.userVerification.rawValue
            credentialRef = value.credentialRef
            storage = value.storage.rawValue
            keySize = value.keySize
            hasPassphrase = value.hasPassphrase
            requiresUserPresence = value.requiresUserPresence
            createdAt = value.createdAt
            colorTag = value.colorTag.rawValue
            sortIndex = value.sortIndex
        }

        private var securityKey: SecurityKeyCredential? {
            guard let securityKeyCredentialID, let securityKeyPublicKey, let securityKeyVerification,
                let verification = SecurityKeyCredential.UserVerification(rawValue: securityKeyVerification)
            else { return nil }
            return SecurityKeyCredential(
                credentialID: securityKeyCredentialID, publicKeyX963: securityKeyPublicKey,
                userVerification: verification, requiresUserPresence: requiresUserPresence)
        }

        public var value: SSHKeyRef {
            SSHKeyRef(
                id: id, label: label,
                algorithm: SSHKeyAlgorithm(rawValue: algorithm) ?? .ed25519,
                publicKey: publicKey, certificate: certificate, fingerprint: fingerprint,
                credentialRef: credentialRef,
                storage: KeyStorage(rawValue: storage) ?? .iCloud,
                securityKey: securityKey,
                keySize: keySize, hasPassphrase: hasPassphrase,
                requiresUserPresence: requiresUserPresence, createdAt: createdAt,
                colorTag: TagColor(rawValue: colorTag) ?? .none, sortIndex: sortIndex
            )
        }
    }
}
