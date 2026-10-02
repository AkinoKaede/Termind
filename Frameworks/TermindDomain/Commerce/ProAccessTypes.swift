import Foundation

public nonisolated enum ProFeature: String, CaseIterable, Hashable, Sendable {
    case assistant
    case remoteMCP
    case mcpServer
    case vaultSync
    case unlimitedMetrics
    case sftpMultiConnection
    case portForwardingMultiConnection
}

public nonisolated enum ProOwnership: Equatable, Sendable {
    case purchased
    case familyShared
}

public nonisolated enum ProSubscriptionPhase: Equatable, Sendable {
    case introductoryTrial
    case subscribed
    case gracePeriod
    case billingRetry
    case expired
    case revoked

    public var hasProAccess: Bool {
        switch self {
        case .introductoryTrial, .subscribed, .gracePeriod: true
        case .billingRetry, .expired, .revoked: false
        }
    }
}

public nonisolated struct ProSubscriptionStatus: Equatable, Sendable {
    public let phase: ProSubscriptionPhase
    public let expiresAt: Date?
    public let willAutoRenew: Bool?
    public let ownership: ProOwnership

    public init(
        phase: ProSubscriptionPhase,
        expiresAt: Date?,
        willAutoRenew: Bool?,
        ownership: ProOwnership
    ) {
        self.phase = phase
        self.expiresAt = expiresAt
        self.willAutoRenew = willAutoRenew
        self.ownership = ownership
    }
}

public nonisolated enum EntitlementStatus: Equatable, Sendable {
    case loading
    case free
    case subscription(ProSubscriptionStatus)
    case purchased(ProOwnership)
    case verificationFailed
    case unrestrictedForTesting

    public var hasProAccess: Bool {
        switch self {
        case .purchased, .unrestrictedForTesting: true
        case .subscription(let subscription): subscription.phase.hasProAccess
        default: false
        }
    }
}
