import Foundation

public nonisolated struct SSHHostKeyIdentity: Hashable, Sendable {
    public var algorithm: SSHKeyAlgorithm
    public var fingerprint: String
    public init(algorithm: SSHKeyAlgorithm, fingerprint: String) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }

}
