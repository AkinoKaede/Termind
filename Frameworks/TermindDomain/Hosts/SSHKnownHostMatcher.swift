import CryptoKit
import Foundation

public nonisolated enum SSHKnownHostMatcher {
    public static func isValidHash(_ hash: String) -> Bool { components(hash) != nil }

    public static func matches(hash: String, hostname: String, port: Int) -> Bool {
        guard let (salt, expected) = components(hash) else { return false }
        let address = port == 22 ? hostname.lowercased() : "[\(hostname.lowercased())]:\(port)"
        let actual = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(address.utf8), using: SymmetricKey(data: salt)
        )
        return Data(actual) == expected
    }

    private static func components(_ hash: String) -> (Data, Data)? {
        let parts = hash.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "1",
            let salt = Data(base64Encoded: String(parts[2])), salt.count == 20,
            let digest = Data(base64Encoded: String(parts[3])), digest.count == 20
        else { return nil }
        return (salt, digest)
    }
}
