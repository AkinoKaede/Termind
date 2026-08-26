import Foundation

nonisolated struct SSHHostKeyIdentity: Hashable, Sendable {
    var algorithm: SSHKeyAlgorithm
    var fingerprint: String
}
