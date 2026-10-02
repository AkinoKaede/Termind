import Foundation
import TermindDomain

@MainActor
@Observable
public final class ProAccessController {
    private let purchaseService: (any ProPurchaseService)?
    private let now: () -> Date
    private var customerInfoUpdates: Task<Void, Never>?
    private var initialRefreshTask: Task<Void, Never>?
    private var accessTask: Task<EntitlementStatus, any Error>?
    private var entitlementExpirationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    public private(set) var status: EntitlementStatus
    public private(set) var isProcessing = false
    public var isPaywallPresented = false
    /// App-owned runtime reconciliation; does not require a visible SwiftUI surface.
    public var accessDidChange: (() -> Void)?

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

    /// Resolve access without changing the user's persisted choice or presenting commerce UI.
    public func effectiveSFTPPreferences(_ saved: SFTPPreferences) -> SFTPPreferences {
        var effective = saved
        if !canUse(.sftpMultiConnection) { effective.strategy = .channelsOnly }
        return effective
    }

    public func effectiveForwardingConnections(_ saved: Int) -> Int {
        canUse(.portForwardingMultiConnection) ? Host.normalizedPortForwardingMaxConnections(saved) : 1
    }

    @discardableResult
    public func require(_ feature: ProFeature) -> Bool {
        guard !canUse(feature) else { return true }
        presentPaywall()
        return false
    }

    public func presentPaywall() {
        isPaywallPresented = true
    }

    /// RevenueCat owns purchases, receipt synchronization, cached access, and subscription updates.
    public func refresh() async {
        guard status != .unrestrictedForTesting else { return }
        guard let purchaseService else {
            apply(.verificationFailed)
            return
        }
        if accessTask == nil {
            refreshGeneration &+= 1
            accessTask = Task { try await purchaseService.currentStatus() }
        }
        let generation = refreshGeneration
        guard let task = accessTask else { return }
        let result = await task.result
        // A newer CustomerInfo update takes precedence over an earlier request.
        guard generation == refreshGeneration, accessTask != nil else { return }
        accessTask = nil
        switch result {
        case .success(let resolved):
            apply(resolved)
        case .failure:
            if status == .loading { apply(.verificationFailed) }
        }
    }

    private func acceptServiceStatus(_ next: EntitlementStatus) {
        refreshGeneration &+= 1
        accessTask?.cancel()
        accessTask = nil
        if next.hasProAccess { isProcessing = false }
        apply(next)
    }

    public func beginPaywallOperation() {
        isProcessing = true
    }

    public func cancelPaywallOperation() { isProcessing = false }

    public func completePaywallOperation() async {
        isProcessing = false
        await refresh()
    }

    private func apply(_ next: EntitlementStatus) {
        let changed = status.hasProAccess != next.hasProAccess
        status = next
        if changed { accessDidChange?() }
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
