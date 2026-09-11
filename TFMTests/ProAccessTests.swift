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
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func trialLastsFourteenDaysWithAnExclusiveExpirationBoundary() {
        let trial = ProTrial(originalID: 1, purchasedAt: start, isRevoked: false)
        #expect(ProTrial.duration == 1_209_600)
        #expect(trial.status(at: start.addingTimeInterval(7 * 86_400)).hasProAccess)
        #expect(trial.status(at: trial.expiresAt.addingTimeInterval(-1)).hasProAccess)
        #expect(trial.status(at: trial.expiresAt) == .trialExpired)
        #expect(trial.status(at: trial.expiresAt.addingTimeInterval(1)) == .trialExpired)
    }

    @Test
    func restoredAndRepeatedPurchasesNeverRestartTrial() {
        let original = ProTrial(originalID: 1, purchasedAt: start, isRevoked: false)
        let later = ProTrial(originalID: 2, purchasedAt: start.addingTimeInterval(86_400), isRevoked: false)
        #expect(ProTrial.earliest([later, original, original]) == original)
        #expect(ProTrial.earliest([]) == nil)
    }

    @Test
    func revocationKeepsTrialClaimedEvenIfPurchasedAgain() {
        let original = ProTrial(originalID: 1, purchasedAt: start, isRevoked: true)
        let later = ProTrial(originalID: 2, purchasedAt: start.addingTimeInterval(86_400), isRevoked: false)
        #expect(ProTrial.earliest([later, original])?.status(at: start) == .trialExpired)
    }

    @Test @MainActor
    func clockRollbackCannotReactivateExpiredTrialOrAffectAnotherTransaction() {
        let suite = "TrialClockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let trial = ProTrial(originalID: 1, purchasedAt: start, isRevoked: false)
        let clock = TrialClock(defaults: defaults)
        #expect(trial.status(at: clock.effectiveNow(for: trial, now: trial.expiresAt)) == .trialExpired)
        let relaunchedClock = TrialClock(defaults: defaults)
        #expect(trial.status(at: relaunchedClock.effectiveNow(for: trial, now: start)) == .trialExpired)
        let other = ProTrial(originalID: 2, purchasedAt: start, isRevoked: false)
        #expect(other.status(at: clock.effectiveNow(for: other, now: start)).hasProAccess)
    }

    @Test
    func entitlementStatesExposeOnlyRealAccess() {
        #expect(!EntitlementStatus.loading.hasProAccess)
        #expect(!EntitlementStatus.free(trialAvailable: true).hasProAccess)
        #expect(!EntitlementStatus.trialExpired.hasProAccess)
        #expect(!EntitlementStatus.verificationFailed.hasProAccess)
        #expect(EntitlementStatus.trialActive(expiresAt: .distantFuture).hasProAccess)
        #expect(EntitlementStatus.purchased(.purchased).hasProAccess)
        #expect(EntitlementStatus.purchased(.familyShared).hasProAccess)
        #expect(EntitlementStatus.unrestrictedForTesting.hasProAccess)
    }

    @Test
    func activeTrialCanStillPurchasePermanentAccess() {
        #expect(EntitlementStatus.trialActive(expiresAt: .distantFuture).canPurchase)
        #expect(!EntitlementStatus.purchased(.purchased).canPurchase)
        #expect(!EntitlementStatus.purchased(.familyShared).canPurchase)
        #expect(!EntitlementStatus.unrestrictedForTesting.canPurchase)
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
