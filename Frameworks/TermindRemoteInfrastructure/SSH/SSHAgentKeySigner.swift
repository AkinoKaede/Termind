import CSSH2
import CryptoKit
import Foundation
import OpenSSL
import TermindApplication
import TermindDomain

/// Uses the same pinned libssh2 OpenSSL parsers as SSH login, including encrypted
/// OpenSSH keys. Parser contexts are local to this operation, never the live session.
nonisolated enum SSHAgentKeySigner {
    static func sign(
        credential: SSHResolvedKeyCredential, passphrase: SSHSecret?,
        algorithm: SSHKeyAlgorithm, data: Data, flags: UInt32, allowInteraction: Bool = true
    ) throws -> Data {
        defer {
            credential.clearSecrets()
            passphrase?.clear()
        }
        guard flags & ~UInt32(6) == 0, algorithm == .rsa || flags == 0 else {
            throw SSHAgentProtocol.Failure.invalid
        }
        let name: String
        let payload: Data
        switch credential {
        case .securityKey: throw SSHInteractionRequired()
        case .secureEnclave(let key):
            guard algorithm == .ecdsa256 else { throw SSHAgentProtocol.Failure.invalid }
            name = algorithm.rawValue
            payload = try SecureEnclaveKey.sign(data, credential: key, allowInteraction: allowInteraction)
        case .software(let secret, let savedPassphrase):
            let passphrase = passphrase ?? savedPassphrase
            defer { savedPassphrase?.clear() }
            defer {
                secret.clear()
                passphrase?.clear()
            }
            _ = initialization
            guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
                throw SSHAgentProtocol.Failure.unavailable
            }
            defer { _ = libssh2_session_free(session) }
            var key: OpaquePointer?
            let parser =
                switch algorithm {
                case .rsa: parseRSA
                case .ed25519: parseEd25519
                default: parseECDSA
                }
            let result = try secret.withUnsafeCStringAndConsume { bytes, count in
                let parse: (UnsafePointer<CChar>?) -> Int32 = { password in
                    parser(&key, session, bytes, count, password)
                }
                if let passphrase { return try passphrase.withUnsafeCStringAndConsume { p, _ in parse(p) } }
                return parse(nil)
            }
            defer { if let key { EVP_PKEY_free(key) } }
            guard result == 0, let key else { throw SSHAgentProtocol.Failure.unavailable }
            var signature: UnsafeMutablePointer<UInt8>?
            var length = 0
            defer { if let signature { libssh2_free(session, signature) } }
            let status: Int32
            switch algorithm {
            case .ed25519:
                name = algorithm.rawValue
                status = data.withUnsafeBytes {
                    signEd25519(key, session, &signature, &length, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                }
            case .rsa:
                let hash: Data
                if flags & 4 != 0 {
                    name = "rsa-sha2-512"
                    hash = Data(SHA512.hash(data: data))
                } else if flags & 2 != 0 {
                    name = "rsa-sha2-256"
                    hash = Data(SHA256.hash(data: data))
                } else {
                    name = "ssh-rsa"
                    hash = Data(Insecure.SHA1.hash(data: data))
                }
                status = hash.withUnsafeBytes {
                    let sign = flags == 0 ? signRSA1 : signRSA2
                    return sign(session, key, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &signature, &length)
                }
            default:
                name = algorithm.rawValue
                let hash: Data =
                    switch algorithm {
                    case .ecdsa384: Data(SHA384.hash(data: data))
                    case .ecdsa521: Data(SHA512.hash(data: data))
                    default: Data(SHA256.hash(data: data))
                    }
                status = hash.withUnsafeBytes {
                    signECDSA(session, key, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &signature, &length)
                }
            }
            guard status == 0, let signature, length > 0 else { throw SSHAgentProtocol.Failure.unavailable }
            payload = Data(bytes: signature, count: length)
        }
        return SSHAgentProtocol.field(Data(name.utf8)) + SSHAgentProtocol.field(payload)
    }
    private static let initialization: Void = { precondition(libssh2_init(0) == 0) }()
}

// libssh2-spm 2.0.3 uses OpenSSL 3 EVP_PKEY contexts for all three parsers.
// These are already shipped symbols, like _libssh2_pub_priv_keyfilememory used
// by SSHKeyMaterial. Keep the independent signature tests when updating libssh2.
@_silgen_name("_libssh2_rsa_new_private_frommemory")
private nonisolated func parseRSA(
    _ key: UnsafeMutablePointer<OpaquePointer?>, _ session: OpaquePointer, _ bytes: UnsafePointer<CChar>, _ count: Int,
    _ passphrase: UnsafePointer<CChar>?
) -> Int32
@_silgen_name("_libssh2_ecdsa_new_private_frommemory")
private nonisolated func parseECDSA(
    _ key: UnsafeMutablePointer<OpaquePointer?>, _ session: OpaquePointer, _ bytes: UnsafePointer<CChar>, _ count: Int,
    _ passphrase: UnsafePointer<CChar>?
) -> Int32
@_silgen_name("_libssh2_ed25519_new_private_frommemory")
private nonisolated func parseEd25519(
    _ key: UnsafeMutablePointer<OpaquePointer?>, _ session: OpaquePointer, _ bytes: UnsafePointer<CChar>, _ count: Int,
    _ passphrase: UnsafePointer<CChar>?
) -> Int32
@_silgen_name("_libssh2_rsa_sha1_sign")
private nonisolated func signRSA1(
    _ session: OpaquePointer, _ key: OpaquePointer, _ hash: UnsafePointer<UInt8>?, _ count: Int,
    _ signature: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ length: UnsafeMutablePointer<Int>
) -> Int32
@_silgen_name("_libssh2_rsa_sha2_sign")
private nonisolated func signRSA2(
    _ session: OpaquePointer, _ key: OpaquePointer, _ hash: UnsafePointer<UInt8>?, _ count: Int,
    _ signature: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ length: UnsafeMutablePointer<Int>
) -> Int32
@_silgen_name("_libssh2_ecdsa_sign")
private nonisolated func signECDSA(
    _ session: OpaquePointer, _ key: OpaquePointer, _ hash: UnsafePointer<UInt8>?, _ count: Int,
    _ signature: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ length: UnsafeMutablePointer<Int>
) -> Int32
@_silgen_name("_libssh2_ed25519_sign")
private nonisolated func signEd25519(
    _ key: OpaquePointer, _ session: OpaquePointer, _ signature: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ length: UnsafeMutablePointer<Int>, _ bytes: UnsafePointer<UInt8>?, _ count: Int
) -> Int32
