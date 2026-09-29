import CryptoKit
import Foundation
import TermindApplication
import TermindDomain

/// Independent WebAuthn/SSH wire adapter. The original clientDataJSON is signed and must never be reserialized.
public nonisolated enum WebAuthnSSH {
    public enum Failure: LocalizedError {
        case invalidCredential, invalidResponse, unsupportedResponse

        public var errorDescription: String? {
            switch self {
            case .invalidCredential: String(localized: "The WebAuthn credential reference is invalid.")
            case .invalidResponse: String(localized: "The WebAuthn response could not be verified.")
            case .unsupportedResponse: String(localized: "The WebAuthn response is not compatible with SSH.")
            }
        }
    }
    public static let algorithm = "sk-ecdsa-sha2-nistp256@openssh.com"
    public static let signatureAlgorithm = "webauthn-sk-ecdsa-sha2-nistp256@openssh.com"

    public static func registration(
        credentialID: Data, attestation: Data, clientDataJSON: Data, challenge: Data,
        userVerification: SecurityKeyCredential.UserVerification
    ) throws -> SecurityKeyCredential {
        try validateClientData(clientDataJSON, type: "webauthn.create", challenge: challenge)
        var cbor = CBORReader(attestation)
        guard case .map(let object) = try cbor.read(), cbor.isAtEnd,
            case .bytes(let auth)? = object[.text("authData")], auth.count >= 55
        else { throw Failure.invalidResponse }
        try validateAuthenticator(auth, requiresVerification: userVerification == .required)
        guard auth[32] & 0x40 != 0 else { throw Failure.invalidResponse }
        let count = Int(auth[53]) << 8 | Int(auth[54])
        guard count > 0, count <= auth.count - 55,
            Data(auth[55..<(55 + count)]) == credentialID
        else { throw Failure.invalidResponse }
        var keyReader = CBORReader(Data(auth.dropFirst(55 + count)))
        guard case .map(let key) = try keyReader.read(),
            key[.integer(1)] == .integer(2), key[.integer(3)] == .integer(-7),
            key[.integer(-1)] == .integer(1),
            case .bytes(let x)? = key[.integer(-2)], x.count == 32,
            case .bytes(let y)? = key[.integer(-3)], y.count == 32
        else { throw Failure.unsupportedResponse }
        if auth[32] & 0x80 != 0 {
            guard case .map = try keyReader.read() else { throw Failure.invalidResponse }
        }
        guard keyReader.isAtEnd else { throw Failure.invalidResponse }
        let credential = SecurityKeyCredential(
            credentialID: credentialID, publicKeyX963: Data([4]) + x + y,
            userVerification: userVerification)
        try validate(credential)
        return credential
    }

    public static func validate(_ credential: SecurityKeyCredential) throws {
        guard !credential.credentialID.isEmpty, credential.credentialID.count <= 1023,
            credential.publicKeyX963.count == 65, credential.publicKeyX963.first == 4
        else { throw Failure.invalidCredential }
        _ = try P256.Signing.PublicKey(x963Representation: credential.publicKeyX963)
    }

    public static func publicBlob(_ credential: SecurityKeyCredential) throws -> Data {
        try validate(credential)
        return SSHWireEncoding.field(Data(algorithm.utf8)) + SSHWireEncoding.field(Data("nistp256".utf8))
            + SSHWireEncoding.field(credential.publicKeyX963)
            + SSHWireEncoding.field(Data(SecurityKeyCredential.relyingParty.utf8))
    }

    public static func keyReference(
        _ credential: SecurityKeyCredential, label: String, colorTag: TagColor = .none
    ) throws -> SSHKeyRef {
        let blob = try publicBlob(credential)
        return SSHKeyRef(
            label: label, algorithm: .securityKey,
            publicKey: "\(algorithm) \(blob.base64EncodedString())", fingerprint: SSHWireEncoding.fingerprint(of: blob),
            storage: .external, securityKey: credential, keySize: 256,
            requiresUserPresence: credential.requiresUserPresence, createdAt: .now, colorTag: colorTag)
    }

    /// Import/export only our RP-bound reference, never an OpenSSH private-key file or another app's credential.
    public static func exportReference(_ credential: SecurityKeyCredential) throws -> String {
        try validate(credential)
        return "termind-fido2-v1:" + (try JSONEncoder().encode(credential)).base64EncodedString()
    }

    public static func readReferenceFile(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try importReference(text)
        return text
    }

    public static func importReference(_ text: String) throws -> SecurityKeyCredential {
        let prefix = "termind-fido2-v1:"
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix), text.utf8.count < 16384,
            let data = Data(base64Encoded: String(text.dropFirst(prefix.count)))
        else { throw Failure.invalidCredential }
        let credential = try JSONDecoder().decode(SecurityKeyCredential.self, from: data)
        try validate(credential)
        return credential
    }

    public static func signature(_ assertion: SecurityKeyAssertion, for request: SecurityKeySigningRequest) throws
        -> Data
    {
        try validate(request.credential)
        guard assertion.credentialID == request.credential.credentialID else { throw Failure.invalidResponse }
        let origin = try validateClientData(
            assertion.clientDataJSON, type: "webauthn.get", challenge: request.challenge)
        let auth = Data(assertion.authenticatorData)
        try validateAuthenticator(
            auth, requiresVerification: request.credential.userVerification == .required,
            requiresPresence: request.credential.requiresUserPresence)
        guard auth[32] & 0x40 == 0 else { throw Failure.invalidResponse }
        let extensions = Data(auth.dropFirst(37))
        if auth[32] & 0x80 != 0 {
            var reader = CBORReader(extensions)
            guard case .map = try reader.read(), reader.isAtEnd else { throw Failure.invalidResponse }
        } else if !extensions.isEmpty {
            throw Failure.invalidResponse
        }
        // OpenSSH verifies this exact prefix, including the unpadded base64url challenge.
        let prefix =
            "{\"type\":\"webauthn.get\",\"challenge\":\"\(base64URL(request.challenge))\",\"origin\":\"\(origin)\""
        guard assertion.clientDataJSON.starts(with: Data(prefix.utf8)) else { throw Failure.unsupportedResponse }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        let publicKey = try P256.Signing.PublicKey(x963Representation: request.credential.publicKeyX963)
        guard publicKey.isValidSignature(signature, for: auth + Data(SHA256.hash(data: assertion.clientDataJSON)))
        else {
            throw Failure.invalidResponse
        }
        let raw = signature.rawRepresentation
        let pair = SSHWireEncoding.mpint(Data(raw.prefix(32))) + SSHWireEncoding.mpint(Data(raw.suffix(32)))
        return SSHWireEncoding.field(Data(signatureAlgorithm.utf8)) + SSHWireEncoding.field(pair) + Data(auth[32..<37])
            + SSHWireEncoding.field(Data(origin.utf8)) + SSHWireEncoding.field(assertion.clientDataJSON)
            + SSHWireEncoding.field(extensions)
    }

    private static func validateAuthenticator(_ data: Data, requiresVerification: Bool, requiresPresence: Bool = true)
        throws
    {
        guard data.count >= 37, data.count <= 65536,
            Data(data.prefix(32)) == Data(SHA256.hash(data: Data(SecurityKeyCredential.relyingParty.utf8))),
            !requiresPresence || data[32] & 1 != 0, !requiresVerification || data[32] & 4 != 0
        else { throw Failure.invalidResponse }
    }

    @discardableResult
    private static func validateClientData(_ data: Data, type: String, challenge: Data) throws -> String {
        guard data.count <= 65536,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == type,
            object["challenge"] as? String == base64URL(challenge),
            let origin = object["origin"] as? String,
            origin == "https://\(SecurityKeyCredential.relyingParty)",
            object["crossOrigin"] == nil || object["crossOrigin"] as? Bool == false
        else { throw Failure.invalidResponse }
        return origin
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

}

/// Bounded definite-length CBOR parser for authenticator data, with duplicate-map-key rejection.
private nonisolated struct CBORReader {
    indirect enum Value: Hashable {
        case integer(Int64)
        case bytes(Data)
        case text(String)
        case array([Value])
        case map([Value: Value])
        case simple(UInt8)
    }
    let bytes: [UInt8]
    var offset = 0
    var isAtEnd: Bool { offset == bytes.count }
    init(_ data: Data) { bytes = Array(data) }

    mutating func read(depth: Int = 0) throws -> Value {
        guard depth < 16, bytes.count <= 65536 else { throw WebAuthnSSH.Failure.invalidResponse }
        let head = try take(1).first!
        let major = head >> 5
        let info = head & 31
        let length: UInt64
        if info < 24 {
            length = UInt64(info)
        } else if info <= 27 {
            length = try take(1 << Int(info - 24)).reduce(0) { ($0 << 8) | UInt64($1) }
        } else {
            throw WebAuthnSSH.Failure.unsupportedResponse
        }
        guard length <= UInt64(Int64.max) else { throw WebAuthnSSH.Failure.invalidResponse }
        switch major {
        case 0: return .integer(Int64(length))
        case 1: return .integer(-1 - Int64(length))
        case 2: return .bytes(Data(try take(Int(length))))
        case 3:
            guard let text = String(bytes: try take(Int(length)), encoding: .utf8) else {
                throw WebAuthnSSH.Failure.invalidResponse
            }
            return .text(text)
        case 4:
            guard length <= 1024 else { throw WebAuthnSSH.Failure.invalidResponse }
            return .array(try (0..<length).map { _ in try read(depth: depth + 1) })
        case 5:
            guard length <= 1024 else { throw WebAuthnSSH.Failure.invalidResponse }
            var map: [Value: Value] = [:]
            for _ in 0..<length {
                let key = try read(depth: depth + 1)
                guard map[key] == nil else { throw WebAuthnSSH.Failure.invalidResponse }
                map[key] = try read(depth: depth + 1)
            }
            return .map(map)
        case 7 where info < 24: return .simple(info)
        default: throw WebAuthnSSH.Failure.unsupportedResponse
        }
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - offset else { throw WebAuthnSSH.Failure.invalidResponse }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }
}
