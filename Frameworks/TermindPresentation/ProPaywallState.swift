import Foundation
import TermindDomain

/// Data-only contract for RevenueCat's remote visibility rules and localized text.
public nonisolated struct ProPaywallState {
    public let hasProAccess: Bool
    public let canManageSubscription: Bool
    public let isFamilyShared: Bool
    public let expiresAt: Date?
    /// Protocol values consumed by the dashboard, never displayed as app copy.
    public let state: String

    public init(status: EntitlementStatus) {
        hasProAccess = status.hasProAccess
        switch status {
        case .subscription(let subscription):
            canManageSubscription = subscription.ownership == .purchased
            isFamilyShared = subscription.ownership == .familyShared
            expiresAt = subscription.expiresAt
            switch subscription.phase {
            case .introductoryTrial: state = "trial"
            case .subscribed:
                switch subscription.willAutoRenew {
                case true: state = "renewing"
                case false: state = "ending"
                case nil: state = "active"
                }
            case .gracePeriod: state = "grace"
            case .billingRetry: state = "retry"
            case .expired: state = "expired"
            case .revoked: state = "revoked"
            }
        default:
            canManageSubscription = false
            expiresAt = nil
            if case .purchased(.familyShared) = status {
                isFamilyShared = true
            } else {
                isFamilyShared = false
            }
            switch status {
            case .loading: state = "loading"
            case .free: state = "free"
            case .purchased: state = "lifetime"
            case .verificationFailed: state = "unverified"
            case .unrestrictedForTesting: state = "development"
            case .subscription: preconditionFailure("Handled above")
            }
        }
    }
}
