import Foundation
import TermindDomain
import TermindPresentation
import Testing

struct ProPaywallStateTests {
    @Test(arguments: [ProOwnership.purchased, .familyShared])
    func lifetimeAccessHasNoRenewalDateOrManagement(ownership: ProOwnership) {
        let state = ProPaywallState(status: .purchased(ownership))
        #expect(state.hasProAccess)
        #expect(state.state == "lifetime")
        #expect(state.expiresAt == nil)
        #expect(!state.canManageSubscription)
        #expect(state.isFamilyShared == (ownership == .familyShared))
    }

    @Test(arguments: [true, false, nil] as [Bool?], [ProOwnership.purchased, .familyShared])
    func renewalStatePreservesAccessAndOwnership(autoRenew: Bool?, ownership: ProOwnership) {
        let state = ProPaywallState(
            status: .subscription(
                .init(
                    phase: .subscribed, expiresAt: .distantFuture, willAutoRenew: autoRenew, ownership: ownership)))
        #expect(state.hasProAccess)
        #expect(state.expiresAt == .distantFuture)
        #expect(state.state == (autoRenew == true ? "renewing" : autoRenew == false ? "ending" : "active"))
        #expect(state.canManageSubscription == (ownership == .purchased))
        #expect(state.isFamilyShared == (ownership == .familyShared))
    }

    @Test(arguments: [
        (ProSubscriptionPhase.introductoryTrial, "trial", true),
        (.gracePeriod, "grace", true),
        (.billingRetry, "retry", false),
        (.expired, "expired", false),
        (.revoked, "revoked", false),
    ])
    func subscriptionPhaseSelectsTheCorrectRemoteVariant(phase: ProSubscriptionPhase, code: String, active: Bool) {
        let state = ProPaywallState(
            status: .subscription(
                .init(
                    phase: phase, expiresAt: .distantFuture, willAutoRenew: nil, ownership: .purchased)))
        #expect(state.state == code)
        #expect(state.hasProAccess == active)
        #expect(state.expiresAt == .distantFuture)
        #expect(state.canManageSubscription)
    }

    @Test
    func missingExpirationDoesNotInventADateAndUnverifiedAccessDoesNotUnlock() {
        let trial = ProPaywallState(
            status: .subscription(
                .init(
                    phase: .introductoryTrial, expiresAt: nil, willAutoRenew: nil, ownership: .familyShared)))
        #expect(trial.hasProAccess)
        #expect(trial.expiresAt == nil)
        #expect(!trial.canManageSubscription)
        let unverified = ProPaywallState(status: .verificationFailed)
        #expect(!unverified.hasProAccess)
        #expect(unverified.state == "unverified")
    }
}
