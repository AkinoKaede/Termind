import Foundation

/// File-transfer concurrency shared by terminal uploads and SFTP browsers.
public nonisolated struct SFTPPreferences: Codable, Hashable, Sendable {
    public static let defaultGlobalLimit = 15
    public static let defaultPerHostLimit = 5
    public static let globalLimitRange = 1...100
    public static let perHostLimitRange = 1...50

    public var globalLimit: Int
    public var perHostLimit: Int

    public init(globalLimit: Int = defaultGlobalLimit, perHostLimit: Int = defaultPerHostLimit) {
        self.globalLimit = min(max(globalLimit, Self.globalLimitRange.lowerBound), Self.globalLimitRange.upperBound)
        self.perHostLimit = min(
            max(perHostLimit, Self.perHostLimitRange.lowerBound),
            Self.perHostLimitRange.upperBound, self.globalLimit)
    }

    public var normalized: Self { Self(globalLimit: globalLimit, perHostLimit: perHostLimit) }

    /// Decoded remote values must be validated before entering the sync journal.
    public var isValid: Bool {
        Self.globalLimitRange.contains(globalLimit)
            && Self.perHostLimitRange.contains(perHostLimit) && perHostLimit <= globalLimit
    }

    public var availablePerHostRange: ClosedRange<Int> {
        Self.perHostLimitRange.lowerBound...min(Self.perHostLimitRange.upperBound, normalized.globalLimit)
    }
}
