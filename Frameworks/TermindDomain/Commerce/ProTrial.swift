import Foundation

/// A verified StoreKit trial keeps its original start even after restoration.
public nonisolated struct ProTrial: Equatable, Sendable {
    public static let duration: TimeInterval = 14 * 24 * 60 * 60

    public let originalID: UInt64
    public let purchasedAt: Date
    public var isRevoked: Bool

    public var expiresAt: Date { purchasedAt.addingTimeInterval(Self.duration) }

    public func status(at now: Date) -> EntitlementStatus {
        isRevoked || now >= expiresAt ? .trialExpired : .trialActive(expiresAt: expiresAt)
    }

    /// History can contain both original and restored transactions. A revocation
    /// or a later purchase must never create a second trial for the same product.
    public static func earliest(_ trials: [ProTrial]) -> ProTrial? {
        guard var first = trials.min(by: { $0.purchasedAt < $1.purchasedAt }) else { return nil }
        first.isRevoked = trials.contains(where: \.isRevoked)
        return first
    }
    public init(originalID: UInt64, purchasedAt: Date, isRevoked: Bool) {
        self.originalID = originalID
        self.purchasedAt = purchasedAt
        self.isRevoked = isRevoked
    }

}
