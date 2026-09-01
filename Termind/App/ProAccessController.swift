import Foundation
import StoreKit

@MainActor
@Observable
final class ProAccessController {
    static let productID = "com.akinokaede.termind.pro"
    static let reviewDemoCode = "TERMIND-REVIEW-2026"

    private static let reviewDemoDefaultsKey = "commerce.pro.review-demo-expired.v1"

    private let trialStore: TrialEligibilityStore?
    private let reviewDefaults: UserDefaults?
    private var transactionUpdates: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var trialExpirationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var hasResolvedLocalState = false

    private(set) var status: EntitlementStatus
    private(set) var product: Product?
    private(set) var error: ProAccessControllerError?
    private(set) var workspaceCompositionGrantedForLaunch: Bool
    private(set) var isReviewDemoModeEnabled: Bool
    var isPaywallPresented = false
    var requestedFeature: ProFeature?

    var displayPrice: String? { product?.displayPrice }
    var hasProAccess: Bool { status.hasProAccess }
    var message: String? { error?.localizedDescription }

    static func live() -> ProAccessController {
        ProAccessController(trialStore: TrialEligibilityStore(), reviewDefaults: .standard)
    }

    static func unrestrictedForTesting() -> ProAccessController {
        ProAccessController(trialStore: nil, reviewDefaults: nil, unrestricted: true)
    }

    static func testing(
        status: EntitlementStatus,
        reviewDefaults: UserDefaults? = nil
    ) -> ProAccessController {
        let controller = ProAccessController(
            trialStore: nil,
            reviewDefaults: reviewDefaults,
            unrestricted: true
        )
        controller.status = status
        controller.workspaceCompositionGrantedForLaunch = status.hasProAccess
        return controller
    }

    private init(
        trialStore: TrialEligibilityStore?,
        reviewDefaults: UserDefaults?,
        unrestricted: Bool = false
    ) {
        self.trialStore = trialStore
        self.reviewDefaults = reviewDefaults
        isReviewDemoModeEnabled = reviewDefaults?.bool(forKey: Self.reviewDemoDefaultsKey) ?? false
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

    @discardableResult
    func activateReviewDemo(using code: String) -> Bool {
        guard
            code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                == Self.reviewDemoCode
        else { return false }

        refreshGeneration &+= 1
        isReviewDemoModeEnabled = true
        reviewDefaults?.set(true, forKey: Self.reviewDemoDefaultsKey)
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

    func refresh() async {
        if status == .unrestrictedForTesting { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        error = nil

        async let ownership = currentOwnership()
        Task { [weak self] in await self?.loadProductMetadata(generation: generation) }

        // CloudKit is intentionally absent from the launch-critical path.
        // A signed local proof can safely grant or refuse a trial immediately;
        // the private CloudKit record only reconciles an earlier start made on
        // another device. StoreKit's current entitlements are local-first too,
        // but should not hold the entire app behind a launch overlay.
        if !hasResolvedLocalState {
            if isReviewDemoModeEnabled {
                apply(.trialExpired)
            } else if let trialStore {
                apply(Self.status(for: await trialStore.assessment(includeCloud: false)))
            } else {
                apply(.free(trialAvailable: false))
            }
            hasResolvedLocalState = true
        }

        let resolvedOwnership = await ownership
        guard generation == refreshGeneration else { return }
        if let resolvedOwnership {
            disableReviewDemo()
            apply(.purchased(resolvedOwnership))
        } else if isReviewDemoModeEnabled {
            apply(.trialExpired)
        } else if let trialStore {
            apply(Self.status(for: await trialStore.assessment()))
        } else {
            apply(.free(trialAvailable: false))
        }

    }

    func startTrial() async {
        guard let trialStore else { return }
        refreshGeneration &+= 1
        error = nil
        do {
            apply(Self.status(for: try await trialStore.start()))
            if !status.hasProAccess {
                error = .trialAlreadyUsed
            } else {
                isPaywallPresented = false
            }
        } catch let startError {
            error = .trialStartFailed(startError.localizedDescription)
        }
    }

    func purchase() async {
        refreshGeneration &+= 1
        error = nil
        do {
            let product = try await loadProduct()
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    if !status.hasProAccess { apply(.verificationFailed) }
                    error = .purchaseVerificationFailed
                    return
                }
                await transaction.finish()
                disableReviewDemo()
                apply(.purchased(Self.ownership(of: transaction)))
                isPaywallPresented = false
            case .pending:
                if !status.hasProAccess { apply(.purchasePending) }
                error = .purchasePending
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch let purchaseError {
            error = Self.proAccessError(
                purchaseError,
                fallback: .purchaseFailed(purchaseError.localizedDescription)
            )
        }
    }

    func restorePurchases() async {
        error = nil
        do {
            try await AppStore.sync()
            await refresh()
            if !status.hasProAccess {
                error = .purchaseNotFound
            } else {
                isPaywallPresented = false
            }
        } catch let restoreError {
            error = .restoreFailed(restoreError.localizedDescription)
        }
    }

    private func loadProduct() async throws -> Product {
        if let product { return product }
        guard let loaded = try await Product.products(for: [Self.productID]).first else {
            throw ProAccessControllerError.productUnavailable
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
            self.error = .productMetadataUnavailable
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

    private func disableReviewDemo() {
        isReviewDemoModeEnabled = false
        reviewDefaults?.removeObject(forKey: Self.reviewDemoDefaultsKey)
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

    private static func proAccessError(
        _ error: any Error,
        fallback: @autoclosure () -> ProAccessControllerError
    ) -> ProAccessControllerError {
        error as? ProAccessControllerError ?? fallback()
    }
}

nonisolated enum ProAccessControllerError: LocalizedError, Equatable, Sendable {
    case productUnavailable
    case productMetadataUnavailable
    case trialAlreadyUsed
    case trialStartFailed(String)
    case purchaseVerificationFailed
    case purchasePending
    case purchaseFailed(String)
    case purchaseNotFound
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "Termind Pro is not available from the App Store right now.")
        case .productMetadataUnavailable:
            String(
                localized: "The App Store is temporarily unavailable. You can keep using already unlocked features."
            )
        case .trialAlreadyUsed:
            String(localized: "This Apple account or Mac has already used the free trial.")
        case .trialStartFailed(let description),
            .purchaseFailed(let description),
            .restoreFailed(let description):
            description
        case .purchaseVerificationFailed:
            String(localized: "The App Store could not verify this purchase.")
        case .purchasePending:
            String(localized: "The purchase is waiting for App Store approval.")
        case .purchaseNotFound:
            String(localized: "No Termind Pro purchase was found for this Apple account.")
        }
    }
}
