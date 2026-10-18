import Foundation
import OpenSSL
import TermindDomain

nonisolated extension SSHKeyMaterial {
    public struct PrivateKeyMetadata: Sendable {
        public var algorithm: SSHKeyAlgorithm
        public var keySize: Int?
        public var isEncrypted: Bool
    }

    /// Reads the key envelope without deriving or populating a public key. An encrypted
    /// PKCS#8 envelope deliberately leaves its algorithm unknown until it is unlocked.
    public static func privateKeyMetadata(_ text: String) throws -> PrivateKeyMetadata {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        guard let header = lines.first, let footer = lines.last,
            header.hasPrefix("-----BEGIN "), header.hasSuffix("PRIVATE KEY-----"),
            footer == header.replacingOccurrences(of: "BEGIN", with: "END")
        else { throw SSHKeyMaterialError.invalidPrivateKey("Invalid private key envelope.") }
        let body = lines.dropFirst().dropLast().filter { !$0.contains(":") }.joined()
        guard let bytes = Data(base64Encoded: body), !bytes.isEmpty else {
            throw SSHKeyMaterialError.invalidPrivateKey("Invalid private key encoding.")
        }
        if header == "-----BEGIN OPENSSH PRIVATE KEY-----" {
            let magic = Data("openssh-key-v1\0".utf8)
            guard bytes.starts(with: magic) else { throw invalidEnvelope }
            var offset = magic.count
            guard let cipher = readSSHField(bytes, offset: &offset),
                let kdf = readSSHField(bytes, offset: &offset),
                let options = readSSHField(bytes, offset: &offset), offset + 4 <= bytes.count
            else { throw invalidEnvelope }
            let count = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard count == 1, let publicBlob = readSSHField(bytes, offset: &offset),
                let privateBlob = readSSHField(bytes, offset: &offset), !privateBlob.isEmpty,
                offset == bytes.count
            else { throw invalidEnvelope }
            var publicOffset = 0
            guard let method = readSSHField(publicBlob, offset: &publicOffset),
                let name = String(data: method, encoding: .utf8)
            else { throw invalidEnvelope }
            let material = try publicMaterial("\(name) \(publicBlob.base64EncodedString())")
            let encrypted = cipher != Data("none".utf8)
            guard encrypted || (kdf == Data("none".utf8) && options.isEmpty && privateBlob.count >= 8) else {
                throw invalidEnvelope
            }
            if !encrypted { try validateOpenSSHPrivateBlock(privateBlob, algorithm: material.algorithm) }
            return PrivateKeyMetadata(
                algorithm: material.algorithm, keySize: material.keySize, isEncrypted: encrypted)
        }
        if header == "-----BEGIN ENCRYPTED PRIVATE KEY-----" {
            let valid = bytes.withUnsafeBytes { buffer -> Bool in
                var pointer = buffer.bindMemory(to: UInt8.self).baseAddress
                let start = pointer
                guard let value = d2i_X509_SIG(nil, &pointer, bytes.count) else { return false }
                defer { X509_SIG_free(value) }
                return pointer == start?.advanced(by: bytes.count)
            }
            guard valid else { throw invalidEnvelope }
            return PrivateKeyMetadata(algorithm: .unknown, keySize: nil, isEncrypted: true)
        }
        if lines.contains(where: { $0.hasPrefix("DEK-Info:") }) {
            guard lines.contains(where: { $0.contains("Proc-Type: 4,ENCRYPTED") }), bytes.count >= 16,
                ["-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----"].contains(header)
            else { throw invalidEnvelope }
            return PrivateKeyMetadata(
                algorithm: header.contains("RSA") ? .rsa : .unknown, keySize: nil, isEncrypted: true)
        }
        return try text.withCString { buffer in
            guard let bio = BIO_new_mem_buf(buffer, Int32(text.utf8.count)) else { throw invalidEnvelope }
            defer { BIO_free(bio) }
            guard let key = PEM_read_bio_PrivateKey(bio, nil, { _, _, _, _ in 0 }, nil) else {
                throw invalidEnvelope
            }
            defer { EVP_PKEY_free(key) }
            let bits = Int(EVP_PKEY_get_bits(key))
            let algorithm: SSHKeyAlgorithm
            switch EVP_PKEY_get_base_id(key) {
            case EVP_PKEY_ED25519: algorithm = .ed25519
            case EVP_PKEY_RSA: algorithm = .rsa
            case EVP_PKEY_EC:
                switch bits {
                case 256: algorithm = .ecdsa256
                case 384: algorithm = .ecdsa384
                case 521: algorithm = .ecdsa521
                default: throw SSHKeyMaterialError.unsupportedAlgorithm("EC \(bits)")
                }
            default: throw SSHKeyMaterialError.unsupportedAlgorithm("PEM")
            }
            return PrivateKeyMetadata(algorithm: algorithm, keySize: bits, isEncrypted: false)
        }
    }

    private static func validateOpenSSHPrivateBlock(_ bytes: Data, algorithm: SSHKeyAlgorithm) throws {
        guard bytes.count >= 8, bytes.prefix(4) == bytes.dropFirst(4).prefix(4) else { throw invalidEnvelope }
        var offset = 8
        guard readSSHField(bytes, offset: &offset) == Data(algorithm.rawValue.utf8) else { throw invalidEnvelope }
        switch algorithm {
        case .ed25519:
            guard let publicKey = readSSHField(bytes, offset: &offset), publicKey.count == 32,
                let privateKey = readSSHField(bytes, offset: &offset), privateKey.count == 64,
                privateKey.suffix(32) == publicKey
            else { throw invalidEnvelope }
        case .rsa:
            for _ in 0..<6 {
                guard let field = readSSHField(bytes, offset: &offset), !field.isEmpty else { throw invalidEnvelope }
            }
        case .ecdsa256, .ecdsa384, .ecdsa521:
            guard readSSHField(bytes, offset: &offset) == Data(algorithm.rawValue.dropFirst(11).utf8),
                let point = readSSHField(bytes, offset: &offset), point.first == 4,
                let scalar = readSSHField(bytes, offset: &offset), !scalar.isEmpty
            else { throw invalidEnvelope }
        case .unknown, .securityKey: throw invalidEnvelope
        }
        guard readSSHField(bytes, offset: &offset) != nil else { throw invalidEnvelope }
        let padding = bytes.dropFirst(offset)
        guard padding.count <= 255,
            padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) })
        else { throw invalidEnvelope }
    }

    public struct ImportAnalysis: Sendable {
        public let metadata: PrivateKeyMetadata
        public let material: Result<SSHKeyMaterial, any Error>
    }

    /// Parses the private envelope once, retaining its metadata even if the supplied public key is invalid.
    public static func analyzeImport(privateKey: String, publicKey: String) throws -> ImportAnalysis {
        let metadata = try privateKeyMetadata(privateKey)
        let material = Result<SSHKeyMaterial, any Error> {
            let publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicKey.isEmpty else {
                return SSHKeyMaterial(
                    privateKey: privateKey, publicKey: "", algorithm: metadata.algorithm,
                    fingerprint: "", keySize: metadata.keySize)
            }
            var material = try publicMaterial(publicKey)
            guard material.algorithm != .securityKey,
                metadata.algorithm == .unknown || material.algorithm == metadata.algorithm
            else { throw SSHUserCertificateError.keyMismatch }
            material.privateKey = privateKey
            return material
        }
        return ImportAnalysis(metadata: metadata, material: material)
    }

    public static func imported(privateKey: String, publicKey: String) throws -> SSHKeyMaterial {
        try analyzeImport(privateKey: privateKey, publicKey: publicKey).material.get()
    }

    /// Validates a single OpenSSH public key, including the method inside its wire blob.
    public static func publicMaterial(_ text: String) throws -> SSHKeyMaterial {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard !text.contains("\n"), !text.contains("\r"), !text.contains("\0"), fields.count >= 2,
            let algorithm = SSHKeyAlgorithm(rawValue: String(fields[0])), algorithm != .unknown,
            let blob = Data(base64Encoded: String(fields[1]))
        else { throw SSHUserCertificateError.invalidFormat }
        var offset = 0
        guard readSSHField(blob, offset: &offset) == Data(fields[0].utf8) else {
            throw SSHUserCertificateError.invalidFormat
        }
        switch algorithm {
        case .ed25519:
            guard readSSHField(blob, offset: &offset)?.count == 32 else { throw SSHUserCertificateError.invalidFormat }
        case .rsa:
            guard let exponent = readSSHField(blob, offset: &offset), !exponent.isEmpty,
                let modulus = readSSHField(blob, offset: &offset), !modulus.isEmpty
            else { throw SSHUserCertificateError.invalidFormat }
        case .ecdsa256, .ecdsa384, .ecdsa521, .securityKey:
            let curve = algorithm == .securityKey ? "nistp256" : String(algorithm.rawValue.dropFirst(11))
            let length = algorithm == .ecdsa521 ? 133 : algorithm == .ecdsa384 ? 97 : 65
            guard readSSHField(blob, offset: &offset) == Data(curve.utf8),
                let point = readSSHField(blob, offset: &offset), point.count == length, point.first == 4
            else { throw SSHUserCertificateError.invalidFormat }
            if algorithm == .securityKey {
                guard let application = readSSHField(blob, offset: &offset), !application.isEmpty else {
                    throw SSHUserCertificateError.invalidFormat
                }
            }
        case .unknown: throw SSHUserCertificateError.invalidFormat
        }
        guard offset == blob.count else { throw SSHUserCertificateError.invalidFormat }
        return SSHKeyMaterial(
            privateKey: "", publicKey: text, algorithm: algorithm,
            fingerprint: SSHWireEncoding.fingerprint(of: blob),
            keySize: inferredKeySize(for: algorithm, publicBlob: blob))
    }

    private static var invalidEnvelope: SSHKeyMaterialError {
        .invalidPrivateKey("Invalid private key envelope.")
    }
}
