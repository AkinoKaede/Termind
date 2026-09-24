import Foundation
import TermindDomain

/// Store-independent values supplied by the platform's commerce adapter.
public nonisolated struct ProPaywallPresentation {
    public var status: EntitlementStatus
    public var annualPrice: String?
    public var lifetimePrice: String?
    public var billingPeriod: DateComponents?
    public var trialDuration: DateComponents?
    public var canStartTrial: Bool
    public var canPurchaseAnnual: Bool
    public var canPurchaseLifetime: Bool
    public var isProcessing: Bool
    public var message: String?
    public var requestedFeature: ProFeature?
    public var supportsMCPServer: Bool

    public init(
        status: EntitlementStatus, annualPrice: String? = nil, lifetimePrice: String? = nil,
        billingPeriod: DateComponents? = nil, trialDuration: DateComponents? = nil,
        canStartTrial: Bool = false, canPurchaseAnnual: Bool = false, canPurchaseLifetime: Bool = false,
        isProcessing: Bool = false, message: String? = nil, requestedFeature: ProFeature? = nil,
        supportsMCPServer: Bool = false
    ) {
        self.status = status
        self.annualPrice = annualPrice
        self.lifetimePrice = lifetimePrice
        self.billingPeriod = billingPeriod
        self.trialDuration = trialDuration
        self.canStartTrial = canStartTrial
        self.canPurchaseAnnual = canPurchaseAnnual
        self.canPurchaseLifetime = canPurchaseLifetime
        self.isProcessing = isProcessing
        self.message = message
        self.requestedFeature = requestedFeature
        self.supportsMCPServer = supportsMCPServer
    }

    public var canManageSubscription: Bool {
        guard case .subscription(let subscription) = status else { return false }
        return subscription.ownership == .purchased
    }

    public var needsProductReload: Bool { annualPrice == nil || lifetimePrice == nil }
    public var showsPurchaseActions: Bool { isProcessing || message != nil || status.canPurchase }

    public func canPurchase(_ plan: ProPurchasePlan) -> Bool {
        guard status.canPurchase, !isProcessing else { return false }
        switch plan {
        case .annual: return annualPrice != nil && canPurchaseAnnual
        case .lifetime: return lifetimePrice != nil && canPurchaseLifetime
        }
    }
}

/// The same entitlement labels and date semantics are used on both platforms.
public nonisolated struct ProAccessPresentation {
    public enum Tone: Sendable { case neutral, active, warning, revoked }

    public let title: LocalizedStringResource
    public let symbol: String
    public let tone: Tone
    public let date: Date?
    public let dateLabel: LocalizedStringResource?
    public let isFamilyShared: Bool

    public init(status: EntitlementStatus) {
        switch status {
        case .loading:
            title = AppStrings.Pro.checkingProgress
            symbol = "arrow.triangle.2.circlepath"
            tone = .neutral
        case .free:
            title = AppStrings.Pro.free
            symbol = "person.crop.circle"
            tone = .neutral
        case .purchased(let ownership):
            title =
                ownership == .familyShared ? AppStrings.Pro.lifetimeAccessFamilyShared : AppStrings.Pro.lifetimeAccess
            symbol = ownership == .familyShared ? "person.3.fill" : "checkmark.seal.fill"
            tone = .active
        case .verificationFailed:
            title = AppStrings.Pro.theAppStoreCouldNotVerifyThisPurchase
            symbol = "exclamationmark.triangle.fill"
            tone = .warning
        case .unrestrictedForTesting:
            title = AppStrings.Settings.developmentAccess
            symbol = "hammer"
            tone = .active
        case .subscription(let subscription):
            self = Self(subscription: subscription)
            return
        }
        date = nil
        dateLabel = nil
        isFamilyShared = false
    }

    private init(subscription: ProSubscriptionStatus) {
        date = subscription.expiresAt
        isFamilyShared = subscription.ownership == .familyShared
        switch subscription.phase {
        case .introductoryTrial:
            title = AppStrings.Pro.freeTrial
            symbol = "clock.fill"
            tone = .warning
            dateLabel = AppStrings.Settings.trialEnds
        case .subscribed:
            title = isFamilyShared ? AppStrings.Settings.annualFamilyShared : AppStrings.Pro.annualSubscription
            symbol = isFamilyShared ? "person.3.fill" : "checkmark.seal.fill"
            tone = .active
            dateLabel =
                subscription.willAutoRenew == false ? AppStrings.Settings.accessEnds : AppStrings.Settings.renews
        case .gracePeriod:
            title = AppStrings.Pro.billingGracePeriod
            symbol = "clock.badge.exclamationmark"
            tone = .warning
            dateLabel = AppStrings.Settings.gracePeriodEnds
        case .billingRetry:
            title = AppStrings.Pro.billingIssue
            symbol = "creditcard.trianglebadge.exclamationmark"
            tone = .warning
            dateLabel = AppStrings.Settings.expired
        case .expired:
            title = AppStrings.Pro.subscriptionExpired
            symbol = "calendar.badge.exclamationmark"
            tone = .warning
            dateLabel = AppStrings.Settings.expired
        case .revoked:
            title = AppStrings.Pro.subscriptionRevoked
            symbol = "xmark.seal"
            tone = .revoked
            dateLabel = AppStrings.Settings.expired
        }
    }
}
