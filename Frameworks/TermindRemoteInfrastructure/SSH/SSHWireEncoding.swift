import CryptoKit
import Foundation

/// RFC 4251 fields shared by public keys, signatures, and agent replies.
nonisolated enum SSHWireEncoding {
    static func uint32(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func field(_ data: Data) -> Data { uint32(UInt32(data.count)) + data }

    /// Encodes a nonnegative integer, including its SSH field length.
    static func mpint<S: DataProtocol>(_ bytes: S) -> Data {
        var value = Data(Data(bytes).drop(while: { $0 == 0 }))
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: value.startIndex) }
        return field(value)
    }

    static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }
}
