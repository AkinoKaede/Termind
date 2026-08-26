import CSSH2
import CryptoKit
import Foundation
import OpenSSL

nonisolated enum SSHKeyMaterialError: LocalizedError {
    case invalidPrivateKey(String)
    case unsupportedAlgorithm(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey(let detail):
            String(localized: "The private key could not be read: \(detail)")
        case .unsupportedAlgorithm(let name):
            String(localized: "Unsupported SSH key algorithm: \(name)")
        case .generationFailed(let detail):
            String(localized: "Key generation failed: \(detail)")
        }
    }
}

nonisolated struct SSHKeyMaterial: Sendable {
    nonisolated enum Cipher: String, CaseIterable, Identifiable, Hashable, Sendable {
        case aes256
        case aes128
        case tripleDES

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .aes256: "AES-256"
            case .aes128: "AES-128"
            case .tripleDES: "3DES"
            }
        }

        fileprivate var openSSLName: String {
            switch self {
            case .aes256: "AES-256-CBC"
            case .aes128: "AES-128-CBC"
            case .tripleDES: "DES-EDE3-CBC"
            }
        }
    }

    nonisolated enum Generation: Hashable, Sendable {
        case ed25519
        case ecdsa(bits: Int)
        case rsa(bits: Int)
    }

    var privateKey: String
    var publicKey: String
    var algorithm: SSHKeyAlgorithm
    var fingerprint: String
    var keySize: Int?

    static func generate(
        _ generation: Generation, comment: String, passphrase: String?,
        cipher: Cipher = .aes256, rounds: Int = 100
    ) throws -> SSHKeyMaterial {
        let key = try generateOpenSSLKey(generation)
        defer { EVP_PKEY_free(key) }
        let passphrase = normalizedPassphrase(passphrase)
        let privateKey = try encodePrivateKey(
            key, passphrase: passphrase, cipher: cipher, rounds: rounds
        )
        return try inspect(
            privateKey: privateKey, passphrase: passphrase,
            comment: comment, keySize: generation.keySize
        )
    }

    static func inspect(
        privateKey: String, passphrase: String?, comment: String = "",
        keySize: Int? = nil
    ) throws -> SSHKeyMaterial {
        _ = initialization
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHKeyMaterialError.invalidPrivateKey("Unable to create a libssh2 parser session.")
        }
        defer { _ = libssh2_session_free(session) }

        var method: UnsafeMutablePointer<UInt8>?
        var methodLength = 0
        var blob: UnsafeMutablePointer<UInt8>?
        var blobLength = 0
        let result = privateKey.withCString { privateBuffer in
            let parse: (UnsafePointer<CChar>?) -> Int32 = { passphraseBuffer in
                termind_libssh2_publickey_from_private_memory(
                    session, &method, &methodLength, &blob, &blobLength,
                    privateBuffer, privateKey.utf8.count, passphraseBuffer
                )
            }
            return normalizedPassphrase(passphrase)?.withCString(parse) ?? parse(nil)
        }
        defer {
            if let method { libssh2_free(session, method) }
            if let blob { libssh2_free(session, blob) }
        }
        guard result == 0, let method, let blob, methodLength > 0, blobLength > 0 else {
            throw SSHKeyMaterialError.invalidPrivateKey(sessionError(session, code: result))
        }

        let methodBytes = UnsafeBufferPointer(start: method, count: methodLength)
        let name = String(decoding: methodBytes, as: UTF8.self)
        let publicBlob = Data(bytes: blob, count: blobLength)
        let algorithm = try algorithm(named: name)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey =
            "\(name) \(publicBlob.base64EncodedString())"
            + (trimmedComment.isEmpty ? "" : " \(trimmedComment)")
        return SSHKeyMaterial(
            privateKey: privateKey, publicKey: publicKey, algorithm: algorithm,
            fingerprint: fingerprint(of: publicBlob),
            keySize: keySize ?? inferredKeySize(for: algorithm, publicBlob: publicBlob)
        )
    }

    private static let initialization: Void = {
        precondition(libssh2_init(0) == 0, "libssh2 initialization failed")
    }()

    private static func generateOpenSSLKey(_ generation: Generation) throws -> OpaquePointer {
        let name: String
        switch generation {
        case .ed25519: name = "ED25519"
        case .ecdsa: name = "EC"
        case .rsa: name = "RSA"
        }
        guard let context = EVP_PKEY_CTX_new_from_name(nil, name, nil) else {
            throw SSHKeyMaterialError.generationFailed(openSSLError())
        }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_keygen_init(context) > 0 else {
            throw SSHKeyMaterialError.generationFailed(openSSLError())
        }
        switch generation {
        case .ed25519:
            break
        case .ecdsa(let bits):
            let curve: String
            switch bits {
            case 256: curve = "prime256v1"
            case 384: curve = "secp384r1"
            case 521: curve = "secp521r1"
            default: throw SSHKeyMaterialError.unsupportedAlgorithm("ECDSA P-\(bits)")
            }
            guard curve.withCString({ EVP_PKEY_CTX_set_group_name(context, $0) }) > 0 else {
                throw SSHKeyMaterialError.generationFailed(openSSLError())
            }
        case .rsa(let bits):
            guard [2048, 3072, 4096].contains(bits) else {
                throw SSHKeyMaterialError.unsupportedAlgorithm("RSA \(bits)")
            }
            guard EVP_PKEY_CTX_set_rsa_keygen_bits(context, Int32(bits)) > 0 else {
                throw SSHKeyMaterialError.generationFailed(openSSLError())
            }
        }
        var key: OpaquePointer?
        guard EVP_PKEY_keygen(context, &key) > 0, let key else {
            throw SSHKeyMaterialError.generationFailed(openSSLError())
        }
        return key
    }

    private static func encodePrivateKey(
        _ key: OpaquePointer, passphrase: String?, cipher: Cipher, rounds: Int
    ) throws -> String {
        _ = initialization
        guard let output = BIO_new(BIO_s_mem()) else {
            throw SSHKeyMaterialError.generationFailed(openSSLError())
        }
        defer { BIO_free(output) }
        let result: Int32
        if let passphrase {
            guard rounds > 0 else {
                throw SSHKeyMaterialError.generationFailed(
                    String(localized: "Rounds must be greater than zero.")
                )
            }
            guard let keyInfo = EVP_PKEY2PKCS8(key) else {
                throw SSHKeyMaterialError.generationFailed(openSSLError())
            }
            defer { PKCS8_PRIV_KEY_INFO_free(keyInfo) }
            guard
                let cipherValue = cipher.openSSLName.withCString({
                    EVP_CIPHER_fetch(nil, $0, nil)
                })
            else {
                throw SSHKeyMaterialError.generationFailed(openSSLError())
            }
            defer { EVP_CIPHER_free(cipherValue) }
            let encrypted = passphrase.withCString { buffer in
                PKCS8_encrypt_ex(
                    -1, cipherValue, buffer, Int32(passphrase.utf8.count),
                    nil, 0, Int32(rounds), keyInfo, nil, nil
                )
            }
            guard let encrypted else {
                throw SSHKeyMaterialError.generationFailed(openSSLError())
            }
            defer { X509_SIG_free(encrypted) }
            result = PEM_write_bio_PKCS8(output, encrypted)
        } else {
            result = PEM_write_bio_PrivateKey(output, key, nil, nil, 0, nil, nil)
        }
        guard result == 1 else {
            throw SSHKeyMaterialError.generationFailed(openSSLError())
        }
        let count = BIO_ctrl_pending(output)
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { bytes in
            BIO_read(output, bytes.baseAddress, Int32(count))
        }
        guard read == count, let text = String(data: data, encoding: .utf8) else {
            throw SSHKeyMaterialError.generationFailed("Unable to encode the generated private key.")
        }
        return text
    }

    private static func algorithm(named name: String) throws -> SSHKeyAlgorithm {
        switch name {
        case "ssh-ed25519": .ed25519
        case "ecdsa-sha2-nistp256": .ecdsa256
        case "ecdsa-sha2-nistp384": .ecdsa384
        case "ecdsa-sha2-nistp521": .ecdsa521
        case "ssh-rsa": .rsa
        default: throw SSHKeyMaterialError.unsupportedAlgorithm(name)
        }
    }

    private static func inferredKeySize(
        for algorithm: SSHKeyAlgorithm, publicBlob: Data
    ) -> Int? {
        switch algorithm {
        case .ed25519: 256
        case .ecdsa256: 256
        case .ecdsa384: 384
        case .ecdsa521: 521
        case .rsa: rsaKeySize(publicBlob)
        }
    }

    private static func rsaKeySize(_ blob: Data) -> Int? {
        var offset = 0
        guard readSSHField(blob, offset: &offset) != nil,
            readSSHField(blob, offset: &offset) != nil,
            let modulus = readSSHField(blob, offset: &offset)
        else { return nil }
        let bytes = modulus.drop(while: { $0 == 0 })
        guard let first = bytes.first else { return nil }
        return (bytes.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    private static func readSSHField(_ data: Data, offset: inout Int) -> Data? {
        guard offset + 4 <= data.count else { return nil }
        let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length >= 0, offset + length <= data.count else { return nil }
        defer { offset += length }
        return data[offset..<(offset + length)]
    }

    private static func normalizedPassphrase(_ value: String?) -> String? {
        value?.isEmpty == false ? value : nil
    }

    private static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }

    private static func sessionError(_ session: OpaquePointer, code: Int32) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length = Int32(0)
        _ = libssh2_session_last_error(session, &message, &length, 0)
        guard let message else { return "libssh2 error \(code)" }
        let bytes = UnsafeBufferPointer(start: message, count: Int(length))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func openSSLError() -> String {
        let code = ERR_get_error()
        guard code != 0 else { return "Unknown OpenSSL error." }
        var buffer = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(code, &buffer, buffer.count)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension SSHKeyMaterial.Generation {
    fileprivate nonisolated var keySize: Int? {
        switch self {
        case .ed25519: 256
        case .ecdsa(let bits), .rsa(let bits): bits
        }
    }
}

/// libssh2's authentication API invokes this same parser when the public-key
/// argument is nil. Using it here keeps imports and authentication consistent,
/// including passphrase-protected OpenSSH keys.
@_silgen_name("_libssh2_pub_priv_keyfilememory")
private nonisolated func termind_libssh2_publickey_from_private_memory(
    _ session: OpaquePointer?,
    _ method: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ methodLength: UnsafeMutablePointer<Int>?,
    _ publicKey: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ publicKeyLength: UnsafeMutablePointer<Int>?,
    _ privateKey: UnsafePointer<CChar>?,
    _ privateKeyLength: Int,
    _ passphrase: UnsafePointer<CChar>?
) -> Int32
