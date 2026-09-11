import Foundation
import StoreKit
import TermindDomain

@MainActor
@Observable
final class ProAccessController {
    static let productID = "com.akinokaede.termind.pro"
    static let trialProductID = "com.akinokaede.termind.pro.trial"
    static let reviewDemoCode = "TERMIND-REVIEW-2026"

    private static let reviewDemoDefaultsKey = "commerce.pro.review-demo-expired.v1"

    private let defaults: UserDefaults?
    private let now: () -> Date
    private var transactionUpdates: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var accessTask: Task<EntitlementStatus, Never>?
    private var metadataTask: Task<Void, Never>?
    private var productsTask: Task<[Product], any Error>?
    private var trialExpirationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var metadataError: ProAccessControllerError?

    private(set) var status: EntitlementStatus
    private(set) var product: Product?
    private(set) var trialProduct: Product?
    private(set) var error: ProAccessControllerError?
    private(set) var isProcessing = false
    private(set) var pendingProductID: String?
    private(set) var workspaceCompositionGrantedForLaunch: Bool
    private(set) var isReviewDemoModeEnabled: Bool
    var isPaywallPresented = false
    var requestedFeature: ProFeature?

    var displayPrice: String? { product?.displayPrice }
    var hasProAccess: Bool { status.hasProAccess }
    var canPurchase: Bool {
        status.canPurchase && !isProcessing && pendingProductID != Self.productID
    }
    var canStartTrial: Bool {
        status == .free(trialAvailable: true) && !isProcessing
            && pendingProductID != Self.trialProductID && product != nil
            && trialProduct.map(Self.isFreeTrialProduct) == true
    }
    var message: String? {
        if let error { return error.localizedDescription }
        if pendingProductID != nil { return ProAccessControllerError.purchasePending.localizedDescription }
        if status.canPurchase, let metadataError {
            if metadataError == .trialUnavailable, status != .free(trialAvailable: true) { return nil }
            return metadataError.localizedDescription
        }
        return nil
    }

    static func live() -> ProAccessController { ProAccessController(defaults: .standard) }

    static func unrestrictedForTesting() -> ProAccessController {
        testing(status: .unrestrictedForTesting)
    }

    static func testing(
        status: EntitlementStatus,
        reviewDefaults: UserDefaults? = nil
    ) -> ProAccessController {
        let controller = ProAccessController(defaults: reviewDefaults, observeStore: false)
        controller.status = status
        controller.workspaceCompositionGrantedForLaunch = status.hasProAccess
        return controller
    }

    init(
        defaults: UserDefaults?,
        now: @escaping () -> Date = { .now },
        observeStore: Bool = true
    ) {
        self.defaults = defaults
        self.now = now
        isReviewDemoModeEnabled = defaults?.bool(forKey: Self.reviewDemoDefaultsKey) ?? false
        status = .loading
        workspaceCompositionGrantedForLaunch = false
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
        trialExpirationTask?.cancel()
    }

    func canUse(_ feature: ProFeature) -> Bool {
        if feature == .workspaceComposition { return workspaceCompositionGrantedForLaunch }
        return status.hasProAccess
    }

    @discardableResult
    func require(_ feature: ProFeature) -> Bool {
        guard !canUse(feature) else { return true }
        requestedFeature = feature
        isPaywallPresented = true
        return false
    }

    func presentPaywall(for feature: ProFeature? = nil) {
        requestedFeature = feature
        isPaywallPresented = true
    }

    @discardableResult
    func activateReviewDemo(using code: String) -> Bool {
        guard code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == Self.reviewDemoCode else {
            return false
        }
        refreshGeneration &+= 1
        accessTask?.cancel()
        accessTask = nil
        isReviewDemoModeEnabled = true
        defaults?.set(true, forKey: Self.reviewDemoDefaultsKey)
        workspaceCompositionGrantedForLaunch = false
        requestedFeature = nil
        error = nil
        apply(.trialExpired)
        return true
    }

    func deactivateReviewDemo() async {
        disableReviewDemo()
        await refresh()
    }

    /// StoreKit's local transactions resolve access independently of network product metadata.
    func refresh() async { await refresh(including: nil) }

    private func refresh(including transaction: Transaction?) async {
        if status == .unrestrictedForTesting { return }
        // Callers awaiting refresh must also wait for a newer, authoritative
        // transaction refresh. Otherwise a timer/activation can supersede the
        // purchase preflight while leaving the caller with stale eligibility.
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
        if case .purchased = resolved {
            disableReviewDemo()
            pendingProductID = nil
        } else if case .trialActive = resolved, pendingProductID == Self.trialProductID {
            pendingProductID = nil
        }
        apply(isReviewDemoModeEnabled ? .trialExpired : resolved)
    }

    func startTrial() async { await purchaseProduct(Self.trialProductID) }
    func purchase() async { await purchaseProduct(Self.productID) }

    private func purchaseProduct(_ id: String) async {
        guard !isProcessing, pendingProductID != id, status.canPurchase else { return }
        isProcessing = true
        error = nil
        defer { isProcessing = false }
        await refresh()
        guard status.canPurchase else { return }
        if id == Self.trialProductID, status != .free(trialAvailable: true) {
            if case .trialActive = status {
                isPaywallPresented = false
            } else {
                error = status == .verificationFailed ? .purchaseVerificationFailed : .trialAlreadyUsed
            }
            return
        }
        do {
            // Recheck metadata immediately before purchase, even if the UI cached it.
            try await fetchProducts()
            guard let product else { throw ProAccessControllerError.productUnavailable }
            let selected: Product
            if id == Self.trialProductID {
                guard let trialProduct, Self.isFreeTrialProduct(trialProduct) else {
                    throw ProAccessControllerError.trialUnavailable
                }
                selected = trialProduct
            } else {
                selected = product
            }
            switch try await selected.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification, transaction.productID == id else {
                    error = .purchaseVerificationFailed
                    return
                }
                disableReviewDemo()
                await refresh(including: transaction)
                // Delivery/denial is resolved before acknowledging the transaction.
                await transaction.finish()
                if status.hasProAccess {
                    isPaywallPresented = false
                } else if status == .trialExpired {
                    error = .trialAlreadyUsed
                }
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

    func restorePurchases() async {
        guard !isProcessing else { return }
        isProcessing = true
        error = nil
        defer { isProcessing = false }
        do {
            try await AppStore.sync()
            await refresh()
            switch status {
            case .purchased, .trialActive:
                isPaywallPresented = false
            case .trialExpired:
                error = .trialAlreadyUsed
            case .verificationFailed:
                error = .purchaseVerificationFailed
            default:
                error = .purchaseNotFound
            }
        } catch {
            self.error = .operationFailed(error.localizedDescription)
        }
    }

    func reloadProducts() async {
        do {
            try await fetchProducts()
        } catch {
            product = nil
            trialProduct = nil
            metadataError = .productMetadataUnavailable
        }
    }

    private func fetchProducts() async throws {
        let task = productsTask ?? Task { try await Product.products(for: [Self.productID, Self.trialProductID]) }
        productsTask = task
        defer { productsTask = nil }
        let loaded = try await task.value
        product = loaded.first { $0.id == Self.productID && $0.type == .nonConsumable }
        trialProduct = loaded.first { $0.id == Self.trialProductID }
        if product == nil {
            metadataError = .productUnavailable
        } else if trialProduct.map(Self.isFreeTrialProduct) != true {
            metadataError = .trialUnavailable
        } else {
            metadataError = nil
        }
    }

    static func isFreeTrialProduct(_ product: Product) -> Bool {
        product.id == trialProductID && product.type == .nonConsumable && product.price == .zero
            && !product.isFamilyShareable
    }

    private func currentStatus(including update: Transaction?) async -> EntitlementStatus {
        // The verified purchase/update can arrive before StoreKit's history cache.
        if let update, update.productID == Self.productID, update.productType == .nonConsumable,
            update.revocationDate == nil
        {
            return .purchased(update.ownershipType == .familyShared ? .familyShared : .purchased)
        }
        var verificationFailed = false
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction)
            where transaction.productID == Self.productID && transaction.revocationDate == nil
                && transaction.productType == .nonConsumable
                && !(update?.productID == Self.productID && update?.revocationDate != nil
                    && update?.originalID == transaction.originalID):
                return .purchased(transaction.ownershipType == .familyShared ? .familyShared : .purchased)
            case .unverified(let transaction, _) where transaction.productID == Self.productID:
                verificationFailed = true
            default: break
            }
        }
        var trials: [ProTrial] = []
        if let update, update.productID == Self.trialProductID { trials.append(Self.trialRecord(update)) }
        var trialVerificationFailed = false
        // Revoked products disappear from currentEntitlements but still count as claimed.
        for await result in Transaction.all {
            switch result {
            case .verified(let transaction) where transaction.productID == Self.trialProductID:
                trials.append(Self.trialRecord(transaction))
            case .unverified(let transaction, _) where transaction.productID == Self.trialProductID:
                trialVerificationFailed = true
            default: break
            }
        }
        // An unverifiable trial-history entry must never become fresh eligibility.
        if trialVerificationFailed { return .verificationFailed }
        guard let trial = ProTrial.earliest(trials) else {
            return verificationFailed ? .verificationFailed : .free(trialAvailable: true)
        }
        return trial.status(at: TrialClock(defaults: defaults).effectiveNow(for: trial, now: now()))
    }

    private static func trialRecord(_ transaction: Transaction) -> ProTrial {
        ProTrial(
            originalID: transaction.originalID, purchasedAt: transaction.originalPurchaseDate,
            isRevoked: transaction.revocationDate != nil || transaction.ownershipType != .purchased
                || transaction.productType != .nonConsumable
        )
    }

    func handleTransactionUpdate(_ update: VerificationResult<Transaction>) async {
        guard [Self.productID, Self.trialProductID].contains(update.unsafePayloadValue.productID) else { return }
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
        if next.hasProAccess { workspaceCompositionGrantedForLaunch = true }
        trialExpirationTask?.cancel()
        if case .trialActive(let expiresAt) = next {
            trialExpirationTask = Task { [weak self] in
                // Recheck at least once a minute, including clock changes and sleep/wake.
                let remaining = min(60, max(0, expiresAt.timeIntervalSince(self?.now() ?? .now)))
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func disableReviewDemo() {
        isReviewDemoModeEnabled = false
        defaults?.removeObject(forKey: Self.reviewDemoDefaultsKey)
    }
}

nonisolated enum ProAccessControllerError: LocalizedError, Equatable, Sendable {
    case productUnavailable
    case productMetadataUnavailable
    case trialUnavailable
    case trialAlreadyUsed
    case purchaseVerificationFailed
    case purchasePending
    case operationFailed(String)
    case purchaseNotFound

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "Termind Pro is not available from the App Store right now.")
        case .productMetadataUnavailable:
            String(localized: "The App Store is temporarily unavailable. You can keep using already unlocked features.")
        case .trialUnavailable:
            String(localized: "The free trial is unavailable from the App Store right now. Please try again later.")
        case .trialAlreadyUsed:
            String(
                localized:
                    "This App Store account has already used the free trial. Restoring it does not restart the trial.")
        case .operationFailed(let description):
            description
        case .purchaseVerificationFailed:
            String(localized: "The App Store could not verify this purchase.")
        case .purchasePending:
            String(localized: "The purchase is waiting for App Store approval.")
        case .purchaseNotFound:
            String(localized: "No Termind Pro purchase or free trial was found for this App Store account.")
        }
    }
}
