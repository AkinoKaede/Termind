import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TermindApplication

public nonisolated enum SecureEnclaveKeyError: LocalizedError {
    case unavailable
    case accessControl(String)
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Secure Enclave is not available on this device.")
        case .accessControl(let detail):
            String(localized: "Secure Enclave access could not be configured: \(detail)")
        case .invalidSignature:
            String(localized: "Secure Enclave returned an invalid P-256 signature.")
        }
    }
}

public nonisolated enum SecureEnclaveKey {
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public static func generate(comment: String, requiresUserPresence: Bool) throws
        -> SecureEnclaveKeyMaterial
    {
        guard isAvailable else { throw SecureEnclaveKeyError.unavailable }

        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requiresUserPresence { flags.insert(.userPresence) }
        var accessError: Unmanaged<CFError>?
        guard
            let accessControl = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &accessError
            )
        else {
            let detail =
                accessError?.takeRetainedValue().localizedDescription
                ?? String(localized: "Unknown Security framework error")
            throw SecureEnclaveKeyError.accessControl(detail)
        }

        let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false,
            accessControl: accessControl
        )
        let publicBlob = sshPublicBlob(for: privateKey.publicKey.x963Representation)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey =
            "ecdsa-sha2-nistp256 \(publicBlob.base64EncodedString())"
            + (trimmedComment.isEmpty ? "" : " \(trimmedComment)")
        return SecureEnclaveKeyMaterial(
            credential: SecureEnclaveKeyCredential(
                dataRepresentation: privateKey.dataRepresentation
            ),
            publicKey: publicKey,
            fingerprint: fingerprint(of: publicBlob)
        )
    }

    /// Returns the SSH ECDSA signature payload: two length-prefixed mpints (r, s).
    /// libssh2 adds the outer algorithm and signature strings around this value.
    public static func sign(_ data: Data, credential: SecureEnclaveKeyCredential, allowInteraction: Bool = true) throws
        -> Data
    {
        guard isAvailable else { throw SecureEnclaveKeyError.unavailable }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        context.localizedReason = String(localized: "Use your Secure Enclave SSH key")
        defer { context.invalidate() }
        do {
            try Task.checkCancellation()
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: credential.dataRepresentation,
                authenticationContext: context
            )
            let rawSignature = try privateKey.signature(for: data).rawRepresentation
            try Task.checkCancellation()
            guard rawSignature.count == 64 else { throw SecureEnclaveKeyError.invalidSignature }
            return sshField(mpint(rawSignature.prefix(32)))
                + sshField(mpint(rawSignature.suffix(32)))
        } catch {
            throw signingError(error)
        }
    }

    static func signingError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSOSStatusErrorDomain, current.code == Int(errSecUserCanceled) {
                return CancellationError()
            }
            if current.domain == LAError.errorDomain,
                [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(
                    current.code)
            {
                return CancellationError()
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return error
    }

    public static func publicBlob(from authorizedKey: String) -> Data? {
        let parts = authorizedKey.split(whereSeparator: \Character.isWhitespace)
        guard parts.count >= 2, parts[0] == "ecdsa-sha2-nistp256" else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    private static func sshPublicBlob(for x963Representation: Data) -> Data {
        sshField(Data("ecdsa-sha2-nistp256".utf8))
            + sshField(Data("nistp256".utf8))
            + sshField(x963Representation)
    }

    private static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }

    private static func mpint<S: DataProtocol>(_ bytes: S) -> Data {
        var value = Data(bytes).drop(while: { $0 == 0 })
        if value.isEmpty { return Data() }
        if value.first.map({ $0 & 0x80 != 0 }) == true {
            value.insert(0, at: value.startIndex)
        }
        return Data(value)
    }

    private static func sshField(_ value: Data) -> Data {
        var length = UInt32(value.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(value)
        return result
    }
}
