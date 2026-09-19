import Foundation

public nonisolated enum SFTPConcurrencyStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case smart
    case channelsOnly = "channels_only"
    case connectionsPreferred = "connections_preferred"

    public static let smartConnectionThreshold: Int64 = 64_000_000
}

/// File-transfer concurrency shared by terminal uploads and SFTP browsers.
public nonisolated struct SFTPPreferences: Codable, Hashable, Sendable {
    public static let defaultGlobalLimit = 30
    public static let defaultPerHostLimit = 10
    public static let globalLimitRange = 1...100
    public static let perHostLimitRange = 1...50

    public var globalLimit: Int
    public var perHostLimit: Int
    public var strategy: SFTPConcurrencyStrategy

    public init(
        globalLimit: Int = defaultGlobalLimit,
        perHostLimit: Int = defaultPerHostLimit,
        strategy: SFTPConcurrencyStrategy = .smart
    ) {
        self.globalLimit = min(max(globalLimit, Self.globalLimitRange.lowerBound), Self.globalLimitRange.upperBound)
        self.perHostLimit = min(
            max(perHostLimit, Self.perHostLimitRange.lowerBound),
            Self.perHostLimitRange.upperBound, self.globalLimit)
        self.strategy = strategy
    }

    public var normalized: Self {
        Self(globalLimit: globalLimit, perHostLimit: perHostLimit, strategy: strategy)
    }

    /// Decoded remote values must be validated before entering the sync journal.
    public var isValid: Bool {
        Self.globalLimitRange.contains(globalLimit)
            && Self.perHostLimitRange.contains(perHostLimit) && perHostLimit <= globalLimit
    }

    public var availablePerHostRange: ClosedRange<Int> {
        Self.perHostLimitRange.lowerBound...min(Self.perHostLimitRange.upperBound, normalized.globalLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case globalLimit, perHostLimit, strategy
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        globalLimit = try values.decodeIfPresent(Int.self, forKey: .globalLimit) ?? Self.defaultGlobalLimit
        perHostLimit = try values.decodeIfPresent(Int.self, forKey: .perHostLimit) ?? Self.defaultPerHostLimit
        strategy = try values.decodeIfPresent(SFTPConcurrencyStrategy.self, forKey: .strategy) ?? .smart
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(globalLimit, forKey: .globalLimit)
        try values.encode(perHostLimit, forKey: .perHostLimit)
        try values.encode(strategy, forKey: .strategy)
    }
}
