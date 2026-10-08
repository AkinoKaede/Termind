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

    /// The value of one ASCII hexadecimal digit, or nil for any other byte.
    static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
