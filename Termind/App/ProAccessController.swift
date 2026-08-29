import Foundation
import StoreKit

@MainActor
@Observable
final class ProAccessController {
    static let productID = "com.akinokaede.termind.pro"

    private let trialStore: TrialEligibilityStore?
    private var transactionUpdates: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var trialExpirationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var hasResolvedLocalState = false

    private(set) var status: EntitlementStatus
    private(set) var product: Product?
    private(set) var message: String?
    private(set) var workspaceCompositionGrantedForLaunch: Bool
    var isPaywallPresented = false
    var requestedFeature: ProFeature?

    var displayPrice: String? { product?.displayPrice }
    var hasProAccess: Bool { status.hasProAccess }

    static func live() -> ProAccessController {
        ProAccessController(trialStore: TrialEligibilityStore())
    }

    static func unrestrictedForTesting() -> ProAccessController {
        ProAccessController(trialStore: nil, unrestricted: true)
    }

    static func testing(status: EntitlementStatus) -> ProAccessController {
        let controller = ProAccessController(trialStore: nil, unrestricted: true)
        controller.status = status
        controller.workspaceCompositionGrantedForLaunch = status.hasProAccess
        return controller
    }

    private init(trialStore: TrialEligibilityStore?, unrestricted: Bool = false) {
        self.trialStore = trialStore
        status = unrestricted ? .unrestrictedForTesting : .loading
        workspaceCompositionGrantedForLaunch = unrestricted
        guard !unrestricted else { return }
        transactionUpdates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update,
                    transaction.productID == Self.productID
                {
                    await transaction.finish()
                }
                await self.refresh()
            }
        }
        refreshTask = Task { [weak self] in await self?.refresh() }
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

    func refresh() async {
        if status == .unrestrictedForTesting { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        message = nil

        async let ownership = currentOwnership()
        Task { [weak self] in await self?.loadProductMetadata(generation: generation) }

        // CloudKit is intentionally absent from the launch-critical path.
        // A signed local proof can safely grant or refuse a trial immediately;
        // the private CloudKit record only reconciles an earlier start made on
        // another device. StoreKit's current entitlements are local-first too,
        // but should not hold the entire app behind a launch overlay.
        if !hasResolvedLocalState {
            if let trialStore {
                apply(Self.status(for: await trialStore.assessment(includeCloud: false)))
            } else {
                apply(.free(trialAvailable: false))
            }
            hasResolvedLocalState = true
        }

        let resolvedOwnership = await ownership
        guard generation == refreshGeneration else { return }
        if let resolvedOwnership {
            apply(.purchased(resolvedOwnership))
        } else if let trialStore {
            apply(Self.status(for: await trialStore.assessment()))
        } else {
            apply(.free(trialAvailable: false))
        }

    }

    func startTrial() async {
        guard let trialStore else { return }
        refreshGeneration &+= 1
        do {
            apply(Self.status(for: try await trialStore.start()))
            if !status.hasProAccess {
                message = String(localized: "This Apple account or Mac has already used the free trial.")
            } else {
                isPaywallPresented = false
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func purchase() async {
        refreshGeneration &+= 1
        message = nil
        do {
            let product = try await loadProduct()
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    if !status.hasProAccess { apply(.verificationFailed) }
                    message = String(localized: "The App Store could not verify this purchase.")
                    return
                }
                await transaction.finish()
                apply(.purchased(Self.ownership(of: transaction)))
                isPaywallPresented = false
            case .pending:
                if !status.hasProAccess { apply(.purchasePending) }
                message = String(localized: "The purchase is waiting for App Store approval.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restorePurchases() async {
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            if !status.hasProAccess {
                message = String(localized: "No Termind Pro purchase was found for this Apple account.")
            } else {
                isPaywallPresented = false
            }
        } catch {
            message = error.localizedDescription
        }
    }

    #if DEBUG
        /// The only shared seam used by the Debug-only entitlement simulator.
        /// Release compilation removes this method before type checking and SIL emission.
        func applyDevelopmentEntitlement(_ next: EntitlementStatus) {
            refreshGeneration &+= 1
            refreshTask?.cancel()
            transactionUpdates?.cancel()
            trialExpirationTask?.cancel()
            hasResolvedLocalState = true
            status = next
            workspaceCompositionGrantedForLaunch = next.hasProAccess
            requestedFeature = nil
            isPaywallPresented = false
            message = nil
        }
    #endif

    private func loadProduct() async throws -> Product {
        if let product { return product }
        guard let loaded = try await Product.products(for: [Self.productID]).first else {
            throw ProPurchaseError.productUnavailable
        }
        product = loaded
        return loaded
    }

    private func loadProductMetadata(generation: UInt64) async {
        do {
            let loaded = try await Product.products(for: [Self.productID]).first
            guard generation == refreshGeneration else { return }
            product = loaded
        } catch {
            guard generation == refreshGeneration else { return }
            message = String(localized: "The App Store is temporarily unavailable. You can keep using already unlocked features.")
        }
    }

    private func currentOwnership() async -> ProOwnership? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                transaction.productID == Self.productID,
                transaction.revocationDate == nil
            else { continue }
            return Self.ownership(of: transaction)
        }
        return nil
    }

    private func apply(_ next: EntitlementStatus) {
        status = next
        if next.hasProAccess { workspaceCompositionGrantedForLaunch = true }
        trialExpirationTask?.cancel()
        if case .trialActive(let expiresAt) = next {
            trialExpirationTask = Task { [weak self] in
                let remaining = max(0, expiresAt.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private static func ownership(of transaction: Transaction) -> ProOwnership {
        transaction.ownershipType == .familyShared ? .familyShared : .purchased
    }

    private static func status(for assessment: TrialAssessment) -> EntitlementStatus {
        switch assessment {
        case .available: .free(trialAvailable: true)
        case .active(let expiresAt): .trialActive(expiresAt: expiresAt)
        case .expired, .recoveryRequired: .trialExpired
        }
    }
}

private enum ProPurchaseError: LocalizedError {
    case productUnavailable

    var errorDescription: String? {
        String(localized: "Termind Pro is not available from the App Store right now.")
    }
}
