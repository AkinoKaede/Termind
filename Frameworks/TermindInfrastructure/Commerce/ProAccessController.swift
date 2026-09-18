import Foundation
import StoreKit
import TermindDomain

@MainActor
@Observable
public final class ProAccessController {
    public static let lifetimeProductID = "com.akinokaede.termind.pro"
    public static let annualProductID = "com.akinokaede.termind.pro.annual"

    private let now: () -> Date
    private var transactionUpdates: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var accessTask: Task<EntitlementStatus, Never>?
    private var metadataTask: Task<Void, Never>?
    private var productsTask: Task<[Product], any Error>?
    private var entitlementExpirationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var metadataError: ProAccessControllerError?

    public private(set) var status: EntitlementStatus
    /// The permanent, non-consumable product. Kept under the existing name for source compatibility.
    public private(set) var product: Product?
    public private(set) var annualProduct: Product?
    public private(set) var isEligibleForAnnualIntroOffer: Bool?
    public private(set) var error: ProAccessControllerError?
    public private(set) var isProcessing = false
    public private(set) var pendingProductID: String?
    public var isPaywallPresented = false
    public var requestedFeature: ProFeature?

    public var displayPrice: String? { product?.displayPrice }
    public var annualDisplayPrice: String? { annualProduct?.displayPrice }
    public var annualBillingPeriod: DateComponents? {
        annualProduct?.subscription.map { Self.dateComponents(for: $0.subscriptionPeriod, count: 1) }
    }
    public var annualIntroOfferDuration: DateComponents? {
        guard let offer = Self.freeIntroductoryOffer(for: annualProduct) else { return nil }
        return Self.dateComponents(for: offer.period, count: offer.periodCount)
    }
    public var hasProAccess: Bool { status.hasProAccess }
    public var canPurchase: Bool { canPurchase(.lifetime) }
    public var canPurchaseAnnual: Bool { canPurchase(.annual) }
    public var canStartTrial: Bool {
        canPurchase(.annual) && isEligibleForAnnualIntroOffer == true
            && Self.freeIntroductoryOffer(for: annualProduct) != nil
    }
    public var message: String? {
        if let error { return error.localizedDescription }
        if pendingProductID != nil { return ProAccessControllerError.purchasePending.localizedDescription }
        if status.canPurchase, let metadataError { return metadataError.localizedDescription }
        return nil
    }

    public static func live() -> ProAccessController { ProAccessController() }

    public static func unrestrictedForTesting() -> ProAccessController {
        testing(status: .unrestrictedForTesting)
    }

    public static func testing(status: EntitlementStatus) -> ProAccessController {
        let controller = ProAccessController(observeStore: false)
        controller.status = status
        return controller
    }

    public init(
        now: @escaping () -> Date = { .now },
        observeStore: Bool = true
    ) {
        self.now = now
        status = .loading
        guard observeStore else { return }
        transactionUpdates = Task { [weak self] in
            for await update in Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                await self.handleTransactionUpdate(update)
            }
        }
        refreshTask = Task { [weak self] in await self?.refresh() }
        metadataTask = Task { [weak self] in await self?.reloadProducts() }
    }

    isolated deinit {
        transactionUpdates?.cancel()
        refreshTask?.cancel()
        accessTask?.cancel()
        metadataTask?.cancel()
        productsTask?.cancel()
        entitlementExpirationTask?.cancel()
    }

    public func canUse(_: ProFeature) -> Bool {
        status.hasProAccess
    }

    public func canPurchase(_ plan: ProPurchasePlan) -> Bool {
        guard status.canPurchase, !isProcessing else { return false }
        switch plan {
        case .annual:
            return pendingProductID != Self.annualProductID && annualProduct != nil
        case .lifetime:
            return pendingProductID != Self.lifetimeProductID && product != nil
        }
    }

    @discardableResult
    public func require(_ feature: ProFeature) -> Bool {
        guard !canUse(feature) else { return true }
        requestedFeature = feature
        isPaywallPresented = true
        return false
    }

    public func presentPaywall(for feature: ProFeature? = nil) {
        requestedFeature = feature
        isPaywallPresented = true
    }

    /// StoreKit's local transactions resolve access independently of network product metadata.
    public func refresh() async { await refresh(including: nil) }

    private func refresh(including transaction: Transaction?) async {
        if status == .unrestrictedForTesting { return }
        if accessTask == nil || transaction != nil {
            accessTask?.cancel()
            refreshGeneration &+= 1
            accessTask = Task { [weak self] in
                await self?.currentStatus(including: transaction) ?? .loading
            }
        }
        let generation = refreshGeneration
        guard let task = accessTask else { return }
        let resolved = await task.value
        guard generation == refreshGeneration else {
            if accessTask != nil { await refresh() }
            return
        }
        guard accessTask != nil else { return }
        accessTask = nil
        switch resolved {
        case .purchased:
            pendingProductID = nil
        case .subscription(let subscription) where subscription.phase.hasProAccess:
            if pendingProductID == Self.annualProductID { pendingProductID = nil }
        default:
            break
        }
        apply(resolved)
    }

    /// Purchases the annual subscription. StoreKit applies its introductory offer for eligible accounts.
    public func purchaseAnnual() async { await purchaseProduct(Self.annualProductID) }
    public func purchaseLifetime() async { await purchaseProduct(Self.lifetimeProductID) }

    private func purchaseProduct(_ id: String) async {
        guard !isProcessing, pendingProductID != id, status.canPurchase else { return }
        isProcessing = true
        error = nil
        defer { isProcessing = false }
        await refresh()
        guard status.canPurchase else { return }
        do {
            try await fetchProducts()
            let selected: Product
            switch id {
            case Self.annualProductID:
                guard let annualProduct else { throw ProAccessControllerError.productUnavailable }
                selected = annualProduct
            case Self.lifetimeProductID:
                guard let product else { throw ProAccessControllerError.productUnavailable }
                selected = product
            default:
                throw ProAccessControllerError.productUnavailable
            }
            switch try await selected.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification, transaction.productID == id else {
                    error = .purchaseVerificationFailed
                    return
                }
                await refresh(including: transaction)
                await transaction.finish()
                if status.hasProAccess { isPaywallPresented = false }
            case .pending:
                pendingProductID = id
            case .userCancelled:
                break
            @unknown default:
                error = .purchaseVerificationFailed
            }
        } catch StoreKitError.userCancelled {
            // Cancellation is not an entitlement change or a failure to display.
        } catch let purchaseError {
            error = purchaseError as? ProAccessControllerError ?? .operationFailed(purchaseError.localizedDescription)
        }
    }

    public func restorePurchases() async {
        guard !isProcessing else { return }
        isProcessing = true
        error = nil
        defer { isProcessing = false }
        do {
            try await AppStore.sync()
            await refresh()
            switch status {
            case .purchased:
                isPaywallPresented = false
            case .subscription(let subscription) where subscription.phase.hasProAccess:
                isPaywallPresented = false
            case .verificationFailed:
                error = .purchaseVerificationFailed
            default:
                error = .purchaseNotFound
            }
        } catch {
            self.error = .operationFailed(error.localizedDescription)
        }
    }

    public func reloadProducts() async {
        do {
            try await fetchProducts()
        } catch {
            product = nil
            annualProduct = nil
            isEligibleForAnnualIntroOffer = nil
            metadataError = .productMetadataUnavailable
        }
    }

    private func fetchProducts() async throws {
        let task =
            productsTask
            ?? Task {
                try await Product.products(for: [Self.lifetimeProductID, Self.annualProductID])
            }
        productsTask = task
        defer { productsTask = nil }
        let loaded = try await task.value
        product = loaded.first { Self.isLifetimeProduct($0) }
        annualProduct = loaded.first { Self.isAnnualSubscription($0) }
        if let subscription = annualProduct?.subscription,
            Self.freeIntroductoryOffer(for: annualProduct) != nil
        {
            isEligibleForAnnualIntroOffer = await subscription.isEligibleForIntroOffer
        } else {
            isEligibleForAnnualIntroOffer = false
        }
        if product == nil, annualProduct == nil {
            metadataError = .productUnavailable
        } else {
            metadataError = nil
        }
        if case .free = status {
            apply(.free(trialAvailable: isEligibleForAnnualIntroOffer == true))
        }
    }

    public static func isLifetimeProduct(_ product: Product) -> Bool {
        product.id == lifetimeProductID && product.type == .nonConsumable && product.isFamilyShareable
    }

    public static func isAnnualSubscription(_ product: Product) -> Bool {
        guard product.id == annualProductID, product.type == .autoRenewable,
            product.isFamilyShareable, let subscription = product.subscription
        else { return false }
        return subscription.subscriptionPeriod.unit == .year && subscription.subscriptionPeriod.value == 1
    }

    public static func freeIntroductoryOffer(for product: Product?) -> Product.SubscriptionOffer? {
        guard let offer = product?.subscription?.introductoryOffer,
            offer.type == .introductory, offer.paymentMode == .freeTrial, offer.price == .zero
        else { return nil }
        return offer
    }

    private func currentStatus(including update: Transaction?) async -> EntitlementStatus {
        let lifetimeResult = await currentLifetimeTransaction(including: update)
        if let lifetime = lifetimeResult.transaction {
            return .purchased(Self.ownership(of: lifetime))
        }

        var verificationFailed = lifetimeResult.verificationFailed
        let annualResult: VerificationResult<Transaction>?
        if let update, update.productID == Self.annualProductID {
            annualResult = .verified(update)
        } else {
            annualResult = await Transaction.latest(for: Self.annualProductID)
        }
        if let annualResult {
            switch annualResult {
            case .verified(let transaction):
                return .subscription(await subscriptionStatus(for: transaction))
            case .unverified:
                verificationFailed = true
            }
        }

        return verificationFailed ? .verificationFailed : .free(trialAvailable: isEligibleForAnnualIntroOffer == true)
    }

    private func currentLifetimeTransaction(
        including update: Transaction?
    ) async -> (transaction: Transaction?, verificationFailed: Bool) {
        if let update, update.productID == Self.lifetimeProductID, update.productType == .nonConsumable,
            update.revocationDate == nil
        {
            return (update, false)
        }
        var verificationFailed = false
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction)
            where
                transaction.productID == Self.lifetimeProductID && transaction.revocationDate == nil
                && transaction.productType == .nonConsumable
                && !(update?.productID == Self.lifetimeProductID && update?.revocationDate != nil
                    && update?.originalID == transaction.originalID):
                return (transaction, false)
            case .unverified(let transaction, _) where transaction.productID == Self.lifetimeProductID:
                verificationFailed = true
            default:
                break
            }
        }
        if let latest = await Transaction.latest(for: Self.lifetimeProductID) {
            switch latest {
            case .verified(let transaction)
            where transaction.revocationDate == nil && transaction.productType == .nonConsumable
                && !(update?.productID == Self.lifetimeProductID && update?.revocationDate != nil
                    && update?.originalID == transaction.originalID):
                return (transaction, false)
            case .unverified:
                verificationFailed = true
            default:
                break
            }
        }
        return (nil, verificationFailed)
    }

    private func subscriptionStatus(for transaction: Transaction) async -> ProSubscriptionStatus {
        let ownership = Self.ownership(of: transaction)
        if transaction.revocationDate != nil || transaction.productType != .autoRenewable {
            return ProSubscriptionStatus(
                phase: .revoked, expiresAt: transaction.expirationDate, willAutoRenew: false,
                ownership: ownership)
        }

        let storeStatus = await transaction.subscriptionStatus
        let renewalInfo: Product.SubscriptionInfo.RenewalInfo?
        if let storeStatus, case .verified(let verified) = storeStatus.renewalInfo {
            renewalInfo = verified
        } else {
            renewalInfo = nil
        }

        if let expiration = transaction.expirationDate, expiration > now(), !transaction.isUpgraded {
            let phase: ProSubscriptionPhase = Self.isIntroductoryTrial(transaction) ? .introductoryTrial : .subscribed
            return ProSubscriptionStatus(
                phase: phase, expiresAt: expiration, willAutoRenew: renewalInfo?.willAutoRenew,
                ownership: ownership)
        }

        switch storeStatus?.state {
        case .inGracePeriod:
            if let graceExpiration = renewalInfo?.gracePeriodExpirationDate, graceExpiration > now() {
                return ProSubscriptionStatus(
                    phase: .gracePeriod, expiresAt: graceExpiration, willAutoRenew: renewalInfo?.willAutoRenew,
                    ownership: ownership)
            }
            return ProSubscriptionStatus(
                phase: .billingRetry, expiresAt: transaction.expirationDate,
                willAutoRenew: renewalInfo?.willAutoRenew, ownership: ownership)
        case .inBillingRetryPeriod:
            return ProSubscriptionStatus(
                phase: .billingRetry, expiresAt: transaction.expirationDate,
                willAutoRenew: renewalInfo?.willAutoRenew, ownership: ownership)
        case .revoked:
            return ProSubscriptionStatus(
                phase: .revoked, expiresAt: transaction.expirationDate, willAutoRenew: false,
                ownership: ownership)
        case .subscribed:
            return ProSubscriptionStatus(
                phase: .subscribed, expiresAt: transaction.expirationDate,
                willAutoRenew: renewalInfo?.willAutoRenew, ownership: ownership)
        case .expired, .none:
            return ProSubscriptionStatus(
                phase: .expired, expiresAt: transaction.expirationDate, willAutoRenew: false,
                ownership: ownership)
        default:
            return ProSubscriptionStatus(
                phase: .expired, expiresAt: transaction.expirationDate, willAutoRenew: false,
                ownership: ownership)
        }
    }

    private static func isIntroductoryTrial(_ transaction: Transaction) -> Bool {
        transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial
    }

    private static func ownership(of transaction: Transaction) -> ProOwnership {
        transaction.ownershipType == .familyShared ? .familyShared : .purchased
    }

    public func handleTransactionUpdate(_ update: VerificationResult<Transaction>) async {
        let knownProductIDs = [Self.lifetimeProductID, Self.annualProductID]
        guard knownProductIDs.contains(update.unsafePayloadValue.productID) else { return }
        if case .verified(let transaction) = update {
            error = nil
            if pendingProductID == transaction.productID { pendingProductID = nil }
            await refresh(including: transaction)
            await transaction.finish()
        } else {
            error = .purchaseVerificationFailed
            await refresh()
        }
    }

    private func apply(_ next: EntitlementStatus) {
        status = next
        entitlementExpirationTask?.cancel()
        let expiresAt: Date?
        switch next {
        case .subscription(let subscription) where subscription.phase.hasProAccess:
            expiresAt = subscription.expiresAt
        default:
            expiresAt = nil
        }
        if let expiresAt {
            entitlementExpirationTask = Task { [weak self] in
                let remaining = min(60, max(0, expiresAt.timeIntervalSince(self?.now() ?? .now)))
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private static func dateComponents(for period: Product.SubscriptionPeriod, count: Int) -> DateComponents {
        let value = period.value * count
        var components = DateComponents()
        switch period.unit {
        case .day: components.day = value
        case .week: components.weekOfYear = value
        case .month: components.month = value
        case .year: components.year = value
        @unknown default: break
        }
        return components
    }

}

public nonisolated enum ProAccessControllerError: LocalizedError, Equatable, Sendable {
    case productUnavailable
    case productMetadataUnavailable
    case purchaseVerificationFailed
    case purchasePending
    case operationFailed(String)
    case purchaseNotFound

    public var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "Termind Pro is not available from the App Store right now.")
        case .productMetadataUnavailable:
            String(localized: "The App Store is temporarily unavailable. You can keep using already unlocked features.")
        case .operationFailed(let description):
            description
        case .purchaseVerificationFailed:
            String(localized: "The App Store could not verify this purchase.")
        case .purchasePending:
            String(localized: "The purchase is waiting for App Store approval.")
        case .purchaseNotFound:
            String(localized: "No active Termind Pro purchase or subscription was found for this App Store account.")
        }
    }
}
