import Foundation

public nonisolated enum ProFeature: String, CaseIterable, Hashable, Sendable {
    case workspaceComposition
    case assistant
    case terminalFileUpload
    case remoteMCP
    case mcpServer
    case vaultSync
    case unlimitedMetrics
}

public nonisolated enum ProOwnership: Equatable, Sendable {
    case purchased
    case familyShared
}

public nonisolated enum EntitlementStatus: Equatable, Sendable {
    case loading
    case free(trialAvailable: Bool)
    case trialActive(expiresAt: Date)
    case trialExpired
    case purchased(ProOwnership)
    case verificationFailed
    case unrestrictedForTesting

    public var hasProAccess: Bool {
        switch self {
        case .trialActive, .purchased, .unrestrictedForTesting: true
        default: false
        }
    }

    public var canPurchase: Bool {
        switch self {
        case .purchased, .unrestrictedForTesting: false
        default: true
        }
    }
}
