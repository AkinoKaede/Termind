import Foundation
import TermindDomain

@MainActor
@Observable
public final class ProAccessController {
    private let purchaseService: (any ProPurchaseService)?
    private let now: () -> Date
    private var customerInfoUpdates: Task<Void, Never>?
    private var initialRefreshTask: Task<Void, Never>?
    private var accessTask: Task<Result<EntitlementStatus, ProAccessControllerError>, Never>?
    private var entitlementExpirationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    public private(set) var status: EntitlementStatus
    public private(set) var error: ProAccessControllerError?
    public private(set) var isProcessing = false
    public var isPaywallPresented = false
    public var requestedFeature: ProFeature?

    public var usesRevenueCat: Bool { purchaseService != nil }
    public var hasProAccess: Bool { status.hasProAccess }

    public static func live() -> ProAccessController {
        let service = RevenueCatConfiguration.bundled().map { RevenueCatProPurchaseService(configuration: $0) }
        return ProAccessController(purchaseService: service)
    }

    public static func unrestrictedForTesting() -> ProAccessController {
        testing(status: .unrestrictedForTesting)
    }

    public static func testing(status: EntitlementStatus) -> ProAccessController {
        let controller = ProAccessController(purchaseService: nil, observeUpdates: false)
        controller.status = status
        return controller
    }

    init(
        purchaseService: (any ProPurchaseService)?,
        now: @escaping () -> Date = { .now },
        observeUpdates: Bool = true
    ) {
        self.purchaseService = purchaseService
        self.now = now
        status = purchaseService == nil ? .verificationFailed : .loading
        guard observeUpdates, let purchaseService else { return }
        let updates = purchaseService.updates
        customerInfoUpdates = Task { [weak self] in
            for await status in updates {
                guard !Task.isCancelled, let self else { return }
                self.acceptServiceStatus(status)
            }
        }
        initialRefreshTask = Task { [weak self] in await self?.refresh() }
    }

    isolated deinit {
        customerInfoUpdates?.cancel()
        initialRefreshTask?.cancel()
        accessTask?.cancel()
        entitlementExpirationTask?.cancel()
    }

    public func canUse(_: ProFeature) -> Bool { hasProAccess }

    @discardableResult
    public func require(_ feature: ProFeature) -> Bool {
        guard !canUse(feature) else { return true }
        presentPaywall(for: feature)
        return false
    }

    public func presentPaywall(for feature: ProFeature? = nil) {
        requestedFeature = feature
        isPaywallPresented = true
    }

    /// RevenueCat owns purchases, receipt synchronization, cached access, and subscription updates.
    public func refresh() async {
        guard status != .unrestrictedForTesting else { return }
        guard let purchaseService else {
            error = .productUnavailable
            apply(.verificationFailed)
            return
        }
        if accessTask == nil {
            refreshGeneration &+= 1
            accessTask = Task {
                do {
                    return .success(try await purchaseService.currentStatus())
                } catch {
                    return .failure(.operationFailed(error.localizedDescription))
                }
            }
        }
        let generation = refreshGeneration
        guard let task = accessTask else { return }
        let result = await task.value
        // A newer CustomerInfo update takes precedence over an earlier request.
        guard generation == refreshGeneration, accessTask != nil else { return }
        accessTask = nil
        switch result {
        case .success(let resolved):
            error = nil
            apply(resolved)
        case .failure(let failure):
            error = failure
            if status == .loading { apply(.verificationFailed) }
        }
    }

    public func restorePurchases() async {
        guard !isProcessing else { return }
        guard let purchaseService else {
            error = .productUnavailable
            return
        }
        beginPaywallOperation()
        defer { isProcessing = false }
        do {
            let restored = try await purchaseService.restore()
            acceptServiceStatus(restored)
            if restored == .verificationFailed {
                error = .purchaseVerificationFailed
            } else if !restored.hasProAccess {
                error = .purchaseNotFound
            }
        } catch {
            self.error = .operationFailed(error.localizedDescription)
        }
    }

    private func acceptServiceStatus(_ next: EntitlementStatus) {
        refreshGeneration &+= 1
        accessTask?.cancel()
        accessTask = nil
        error = nil
        if next.hasProAccess { isProcessing = false }
        apply(next)
    }

    public func beginPaywallOperation() {
        isProcessing = true
        error = nil
    }

    public func cancelPaywallOperation() { isProcessing = false }

    public func completePaywallOperation() async {
        isProcessing = false
        await refresh()
    }

    private func apply(_ next: EntitlementStatus) {
        status = next
        entitlementExpirationTask?.cancel()
        if case .subscription(let subscription) = next,
            subscription.phase.hasProAccess, let expiresAt = subscription.expiresAt, expiresAt > now()
        {
            entitlementExpirationTask = Task { [weak self] in
                let remaining = max(0, expiresAt.timeIntervalSince(self?.now() ?? .now))
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

public nonisolated enum ProAccessControllerError: LocalizedError, Equatable, Sendable {
    case productUnavailable
    case purchaseVerificationFailed
    case operationFailed(String)
    case purchaseNotFound

    public var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "Termind Pro is not available from the App Store right now.")
        case .operationFailed(let description):
            description
        case .purchaseVerificationFailed:
            String(localized: "The App Store could not verify this purchase.")
        case .purchaseNotFound:
            String(localized: "No active Termind Pro purchase or subscription was found for this App Store account.")
        }
    }
}
