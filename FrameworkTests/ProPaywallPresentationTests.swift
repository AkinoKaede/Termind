import Foundation
import TermindDomain
import TermindPresentation
import Testing

struct ProPaywallPresentationTests {
    @Test(arguments: [
        (ProSubscriptionPhase.introductoryTrial, "Free Trial", "Trial Ends"),
        (.subscribed, "Annual Subscription", "Renews"),
        (.gracePeriod, "Billing Grace Period", "Grace Period Ends"),
        (.billingRetry, "Billing Issue", "Expired"),
        (.expired, "Subscription Expired", "Expired"),
        (.revoked, "Subscription Revoked", "Expired"),
    ])
    func subscriptionKeepsItsStatusAndDateMeaning(phase: ProSubscriptionPhase, title: String, dateLabel: String) {
        let status = subscription(phase: phase)
        let access = ProAccessPresentation(status: status)
        #expect(access.title.key == title)
        #expect(access.dateLabel?.key == dateLabel)
        #expect(access.date == .distantFuture)
        #expect(ProPaywallPresentation(status: status).canManageSubscription)
    }

    @Test(arguments: [ProOwnership.purchased, .familyShared])
    func canceledRenewalKeepsAccessAndShowsTheAccessEnd(ownership: ProOwnership) {
        let status = subscription(phase: .subscribed, ownership: ownership, autoRenew: false)
        let access = ProAccessPresentation(status: status)
        #expect(access.dateLabel?.key == AppStrings.Settings.accessEnds.key)
        #expect(status.hasProAccess)
        #expect(!ProPaywallPresentation(status: status).showsPurchaseActions)
        #expect(ProPaywallPresentation(status: status).canManageSubscription == (ownership == .purchased))
    }

    @Test(arguments: [
        ProSubscriptionPhase.introductoryTrial, .subscribed, .gracePeriod, .billingRetry, .expired, .revoked,
    ])
    func sharedSubscriptionsIdentifyTheOwnerWithoutOfferingManagement(phase: ProSubscriptionPhase) {
        let status = subscription(phase: phase, ownership: .familyShared)
        #expect(ProAccessPresentation(status: status).isFamilyShared)
        #expect(!ProPaywallPresentation(status: status).canManageSubscription)
    }

    @Test(arguments: [
        (EntitlementStatus.loading, "Checking…"),
        (.free(trialAvailable: true), "Free"),
        (.purchased(.purchased), "Lifetime Access"),
        (.purchased(.familyShared), "Lifetime Access · Family Shared"),
        (.verificationFailed, "The App Store could not verify this purchase."),
        (.unrestrictedForTesting, "Development Access"),
    ])
    func nonSubscriptionStatesNeverShowSubscriptionDatesOrManagement(status: EntitlementStatus, title: String) {
        let access = ProAccessPresentation(status: status)
        #expect(access.title.key == title)
        #expect(access.date == nil)
        #expect(access.dateLabel == nil)
        #expect(!ProPaywallPresentation(status: status).canManageSubscription)
    }

    @Test
    func missingPricesAndProcessingPreventPurchasesWithoutHidingRecovery() {
        var presentation = ProPaywallPresentation(
            status: .free(trialAvailable: false), lifetimePrice: "$49.99",
            canPurchaseAnnual: true, canPurchaseLifetime: true)
        #expect(presentation.needsProductReload)
        #expect(!presentation.canPurchase(.annual))
        #expect(presentation.canPurchase(.lifetime))
        presentation.annualPrice = "$19.99"
        #expect(!presentation.needsProductReload)
        #expect(presentation.canPurchase(.annual))
        presentation.canPurchaseAnnual = false
        #expect(!presentation.canPurchase(.annual))
        #expect(presentation.canPurchase(.lifetime))
        presentation.isProcessing = true
        #expect(!presentation.canPurchase(.lifetime))
        #expect(presentation.showsPurchaseActions)
    }

    @Test
    func activeAccessStillShowsRestoreProgressAndErrors() {
        var presentation = ProPaywallPresentation(status: .purchased(.purchased))
        #expect(!presentation.showsPurchaseActions)
        presentation.isProcessing = true
        #expect(presentation.showsPurchaseActions)
        presentation.isProcessing = false
        presentation.message = "Restore failed"
        #expect(presentation.showsPurchaseActions)
        #expect(!presentation.canPurchase(.annual))
        #expect(!presentation.canPurchase(.lifetime))
    }

    private func subscription(
        phase: ProSubscriptionPhase, ownership: ProOwnership = .purchased, autoRenew: Bool = true
    ) -> EntitlementStatus {
        .subscription(
            ProSubscriptionStatus(
                phase: phase, expiresAt: .distantFuture, willAutoRenew: autoRenew, ownership: ownership))
    }
}
