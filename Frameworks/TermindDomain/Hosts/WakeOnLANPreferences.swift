import Foundation

/// A unicast hardware address, normalized for storage and packet construction.
public nonisolated struct MACAddress: Hashable, Sendable, Codable {
    public let rawValue: String

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator: Character = text.contains(":") ? ":" : "-"
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }),
            parts.allSatisfy({ $0.utf8.allSatisfy { $0.isHexDigit } })
        else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes[0] & 1 == 0, bytes.contains(where: { $0 != 0 }) else { return nil }
        rawValue = parts.map { $0.uppercased() }.joined(separator: ":")
    }

    public var magicPacket: Data {
        let bytes = rawValue.split(separator: ":").map { UInt8($0, radix: 16)! }
        return Data(Array(repeating: UInt8(0xFF), count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid MAC address")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated extension UInt8 {
    fileprivate var isHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}

public nonisolated struct WakeOnLANPreferences: Codable, Hashable, Sendable {
    public var macAddress: String
    public var automaticallyWake: Bool

    public init(macAddress: String = "", automaticallyWake: Bool = false) {
        self.macAddress = macAddress
        self.automaticallyWake = automaticallyWake
    }

    public var address: MACAddress? { MACAddress(macAddress) }
    public var isValid: Bool { macAddress.isEmpty ? !automaticallyWake : address != nil }
}
