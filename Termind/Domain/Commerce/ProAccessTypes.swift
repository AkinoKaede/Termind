import Foundation

nonisolated enum ProFeature: String, CaseIterable, Hashable, Sendable {
    case workspaceComposition
    case assistant
    case terminalFileUpload
    case remoteMCP
    case mcpServer
    case vaultSync
}

nonisolated enum ProOwnership: Equatable, Sendable {
    case purchased
    case familyShared
}

nonisolated enum EntitlementStatus: Equatable, Sendable {
    case loading
    case free(trialAvailable: Bool)
    case trialActive(expiresAt: Date)
    case trialExpired
    case purchased(ProOwnership)
    case purchasePending
    case verificationFailed
    case unrestrictedForTesting

    var hasProAccess: Bool {
        switch self {
        case .trialActive, .purchased, .unrestrictedForTesting: true
        default: false
        }
    }
}

nonisolated enum TrialAssessment: Equatable, Sendable {
    case available
    case active(expiresAt: Date)
    case expired
    case recoveryRequired
}
