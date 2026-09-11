import Foundation

/// The normalized portion of `os-release` that is safe and useful after an SSH
/// session ends. It deliberately excludes a version: host artwork represents a
/// distribution family, and persisting every point upgrade would create noisy
/// Vault mutations without changing presentation.
public nonisolated struct DetectedDistribution: Codable, Hashable, Sendable {
    public var id: String
    public var likeIDs: [String]

    public init?(id: String, likeIDs: [String] = []) {
        guard let id = RemoteSystemIdentifier.normalized(id) else { return nil }
        self.id = id
        self.likeIDs = RemoteSystemIdentifier.normalizedList(likeIDs)
            .filter { $0 != id }
    }

    private enum CodingKeys: String, CodingKey { case id, likeIDs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let proposedID = try container.decode(String.self, forKey: .id)
        let proposedLikeIDs =
            try container.decodeIfPresent(
                [String].self, forKey: .likeIDs
            ) ?? []
        guard let value = Self(id: proposedID, likeIDs: proposedLikeIDs) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "Invalid distribution identifier"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !likeIDs.isEmpty { try container.encode(likeIDs, forKey: .likeIDs) }
    }
}

/// Shared validation for remote system tokens and Vault-restored distribution
/// identifiers. Keeping one grammar prevents a synced Host from bypassing the
/// validation applied to live SSH probe output.
public nonisolated enum RemoteSystemIdentifier {
    public static let maximumTokenBytes = 64
    public static let maximumListCount = 8
    public static let maximumListBytes = 256

    public static func sanitized(_ proposed: String?) -> String? {
        guard let proposed else { return nil }
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumTokenBytes,
            value.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
                case 0x2B, 0x2D, 0x2E, 0x5F: true  // + - . _
                default: false
                }
            })
        else { return nil }
        return value
    }

    public static func normalized(_ proposed: String?) -> String? {
        sanitized(proposed)?.lowercased()
    }

    public static func normalizedList(_ proposed: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var byteCount = 0
        for raw in proposed {
            guard result.count < maximumListCount, let value = normalized(raw),
                seen.insert(value).inserted
            else { continue }
            let nextByteCount = byteCount + value.utf8.count + (result.isEmpty ? 0 : 1)
            guard nextByteCount <= maximumListBytes else { break }
            result.append(value)
            byteCount = nextByteCount
        }
        return result
    }
}
