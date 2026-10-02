import Foundation
import RevenueCat
import TermindDomain

nonisolated enum RevenueCatEntitlementResolver {
    static func resolve(_ info: CustomerInfo, entitlementID: String, now: Date) -> EntitlementStatus {
        guard info.entitlements.verification != .failed else { return .verificationFailed }
        guard let entitlement = info.entitlements.all[entitlementID] else { return .free }
        guard entitlement.verification != .failed else { return .verificationFailed }
        let ownership: ProOwnership = entitlement.ownershipType == .familyShared ? .familyShared : .purchased
        if entitlement.expirationDate == nil {
            return entitlement.isActive ? .purchased(ownership) : .free
        }
        let subscription = info.subscriptionsByProductIdentifier[entitlement.productIdentifier]
        let expiration = entitlement.expirationDate
        let phase: ProSubscriptionPhase
        let deadline: Date?
        if subscription?.refundedAt != nil {
            phase = .revoked
            deadline = expiration
        } else if entitlement.isActive, let grace = subscription?.gracePeriodExpiresDate,
            grace > now, subscription?.billingIssuesDetectedAt != nil
        {
            phase = .gracePeriod
            deadline = grace
        } else if entitlement.isActive, let expiration, expiration > now {
            phase = entitlement.periodType == .trial ? .introductoryTrial : .subscribed
            deadline = expiration
        } else {
            phase = entitlement.billingIssueDetectedAt == nil ? .expired : .billingRetry
            deadline = expiration
        }
        return .subscription(
            ProSubscriptionStatus(
                phase: phase, expiresAt: deadline, willAutoRenew: entitlement.willRenew, ownership: ownership))
    }
}
