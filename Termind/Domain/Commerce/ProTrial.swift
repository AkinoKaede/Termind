import Foundation

/// A verified StoreKit trial keeps its original start even after restoration.
nonisolated struct ProTrial: Equatable, Sendable {
    static let duration: TimeInterval = 14 * 24 * 60 * 60

    let originalID: UInt64
    let purchasedAt: Date
    var isRevoked: Bool

    var expiresAt: Date { purchasedAt.addingTimeInterval(Self.duration) }

    func status(at now: Date) -> EntitlementStatus {
        isRevoked || now >= expiresAt ? .trialExpired : .trialActive(expiresAt: expiresAt)
    }

    /// History can contain both original and restored transactions. A revocation
    /// or a later purchase must never create a second trial for the same product.
    static func earliest(_ trials: [ProTrial]) -> ProTrial? {
        guard var first = trials.min(by: { $0.purchasedAt < $1.purchasedAt }) else { return nil }
        first.isRevoked = trials.contains(where: \.isRevoked)
        return first
    }
}
