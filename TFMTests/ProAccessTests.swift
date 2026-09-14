import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

struct ProAccessTests {
    @Test
    func entitlementStatesExposeOnlyRealAccess() {
        #expect(!EntitlementStatus.loading.hasProAccess)
        #expect(!EntitlementStatus.free(trialAvailable: true).hasProAccess)
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

    @Test @MainActor
    func freeAccessRefusesAssistantBeforeAnyCallerCanProceed() {
        let access = ProAccessController.testing(status: .free(trialAvailable: true))
        #expect(!access.require(.assistant))
        #expect(access.isPaywallPresented)
        #expect(access.requestedFeature == .assistant)
        access.isPaywallPresented = false
        #expect(!access.require(.terminalFileUpload))
        #expect(access.isPaywallPresented)
        #expect(access.requestedFeature == .terminalFileUpload)
    }
}
