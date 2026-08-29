import Foundation
import Testing

@testable import Termind

struct ProAccessTests {
    @Test
    func trialProofRoundTripsAndRejectsTampering() throws {
        let key = Data(repeating: 0xA5, count: 32)
        let proof = TrialProof(
            installationID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastTrustedAt: Date(timeIntervalSince1970: 1_700_000_100),
            nonce: Data(repeating: 0x42, count: 32)
        )
        let signed = try TrialProofCodec.sign(proof, key: key)
        #expect(try TrialProofCodec.verify(signed, key: key) == proof)

        var envelope = try JSONDecoder().decode(SignedTrialProof.self, from: signed)
        envelope.proof.startedAt = envelope.proof.startedAt.addingTimeInterval(-3_600)
        let tampered = try JSONEncoder().encode(envelope)
        #expect(try TrialProofCodec.verify(tampered, key: key) == nil)
        #expect(
            try TrialProofCodec.verify(signed, key: Data(repeating: 0x5A, count: 32)) == nil
        )
    }

    @Test
    func entitlementStatesExposeOnlyRealAccess() {
        #expect(!EntitlementStatus.loading.hasProAccess)
        #expect(!EntitlementStatus.free(trialAvailable: true).hasProAccess)
        #expect(!EntitlementStatus.trialExpired.hasProAccess)
        #expect(!EntitlementStatus.purchasePending.hasProAccess)
        #expect(!EntitlementStatus.verificationFailed.hasProAccess)
        #expect(EntitlementStatus.trialActive(expiresAt: .distantFuture).hasProAccess)
        #expect(EntitlementStatus.purchased(.purchased).hasProAccess)
        #expect(EntitlementStatus.purchased(.familyShared).hasProAccess)
    }

    @Test
    func installKeyServicesCannotOverlapUserCredentialServices() {
        let reserved = [
            TrialKeychainStore.installKeyService,
            TrialKeychainStore.proofService,
        ]
        #expect(reserved.allSatisfy { $0.contains("commerce") })
        #expect(reserved.allSatisfy { !$0.contains("passwords") })
        #expect(reserved.allSatisfy { !$0.contains("ssh-software-keys") })
        #expect(reserved.allSatisfy { !$0.contains("secure-enclave-handles") })
    }

    @Test
    func trialDurationIsExactlySevenDays() {
        #expect(TrialEligibilityStore.duration == 7 * 24 * 60 * 60)
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
