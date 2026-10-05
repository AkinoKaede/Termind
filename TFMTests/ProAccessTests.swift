import Foundation
import TermindDomain
import TermindInfrastructure
import Testing

struct ProAccessTests {
    @Test
    func entitlementStatesExposeOnlyRealAccess() {
        #expect(!EntitlementStatus.loading.hasProAccess)
        #expect(!EntitlementStatus.free.hasProAccess)
        #expect(!EntitlementStatus.verificationFailed.hasProAccess)
        #expect(EntitlementStatus.purchased(.purchased).hasProAccess)
        #expect(EntitlementStatus.purchased(.familyShared).hasProAccess)
        #expect(
            EntitlementStatus.subscription(
                ProSubscriptionStatus(
                    phase: .introductoryTrial, expiresAt: .distantFuture, willAutoRenew: true,
                    ownership: .purchased)
            ).hasProAccess)
        #expect(
            EntitlementStatus.subscription(
                ProSubscriptionStatus(
                    phase: .gracePeriod, expiresAt: .distantFuture, willAutoRenew: true,
                    ownership: .purchased)
            ).hasProAccess)
        #expect(
            !EntitlementStatus.subscription(
                ProSubscriptionStatus(
                    phase: .billingRetry, expiresAt: .now, willAutoRenew: true,
                    ownership: .purchased)
            ).hasProAccess)
        #expect(EntitlementStatus.unrestrictedForTesting.hasProAccess)
    }

    @Test(arguments: ProFeature.allCases) @MainActor
    func freeAccessRefusesEveryPaidFeatureBeforeAnyCallerCanProceed(feature: ProFeature) {
        let access = ProAccessController.testing(status: .free)
        #expect(!access.canUse(feature))
        #expect(!access.require(feature))
        #expect(access.isPaywallPresented)
    }
}
