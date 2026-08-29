import Foundation

enum DebugProAccessPreset: String, CaseIterable, Identifiable, Sendable {
    case developerPro
    case freeTrialAvailable
    case trialActive
    case trialExpired
    case purchased
    case familyShared
    case purchasePending
    case verificationFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developerPro: "Developer Pro"
        case .freeTrialAvailable: "Free / Trial Available"
        case .trialActive: "Trial Active"
        case .trialExpired: "Trial Expired"
        case .purchased: "Purchased"
        case .familyShared: "Family Shared"
        case .purchasePending: "Purchase Pending"
        case .verificationFailed: "Verification Failed"
        }
    }

    func entitlementStatus(now: Date = .now) -> EntitlementStatus {
        switch self {
        case .developerPro: .unrestrictedForTesting
        case .freeTrialAvailable: .free(trialAvailable: true)
        case .trialActive:
            .trialActive(expiresAt: now.addingTimeInterval(TrialEligibilityStore.duration))
        case .trialExpired: .trialExpired
        case .purchased: .purchased(.purchased)
        case .familyShared: .purchased(.familyShared)
        case .purchasePending: .purchasePending
        case .verificationFailed: .verificationFailed
        }
    }

    init(status: EntitlementStatus) {
        switch status {
        case .unrestrictedForTesting: self = .developerPro
        case .free: self = .freeTrialAvailable
        case .trialActive: self = .trialActive
        case .trialExpired: self = .trialExpired
        case .purchased(.purchased): self = .purchased
        case .purchased(.familyShared): self = .familyShared
        case .purchasePending: self = .purchasePending
        case .verificationFailed: self = .verificationFailed
        case .loading: self = .developerPro
        }
    }
}

extension ProAccessController {
    static func developmentDefault() -> ProAccessController {
        .unrestrictedForTesting()
    }

    var developmentPreset: DebugProAccessPreset {
        DebugProAccessPreset(status: status)
    }

    func selectDevelopmentPreset(_ preset: DebugProAccessPreset, now: Date = .now) {
        applyDevelopmentEntitlement(preset.entitlementStatus(now: now))
    }

    func resetTrialStorageForDevelopment() async throws {
        try await TrialEligibilityStore().resetForTesting()
        selectDevelopmentPreset(.freeTrialAvailable)
    }
}
