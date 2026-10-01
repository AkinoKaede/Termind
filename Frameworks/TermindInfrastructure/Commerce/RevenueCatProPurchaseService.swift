import Foundation
import RevenueCat
import TermindApplication
import TermindDomain

@MainActor
final class RevenueCatProPurchaseService: ProPurchaseService {
    private let purchases: Purchases
    private let configuration: RevenueCatConfiguration
    private let defaults: UserDefaults
    private let now: () -> Date
    private var updateTask: Task<Void, Never>?
    private var attemptedMigration = false
    private let continuation: AsyncStream<EntitlementStatus>.Continuation
    let updates: AsyncStream<EntitlementStatus>

    init(
        configuration: RevenueCatConfiguration, defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }
    ) {
        self.configuration = configuration
        self.defaults = defaults
        self.now = now
        // Both platforms use anonymous IDs. Restoring a universal Apple purchase aliases these IDs.
        // Never use the device ID or iCloud account as a custom RevenueCat user ID.
        if !Purchases.isConfigured {
            Purchases.configure(
                with: Configuration.builder(withAPIKey: configuration.apiKey)
                    .with(storeKitVersion: .storeKit2)
                    .with(entitlementVerificationMode: .informational)
                    .with(automaticDeviceIdentifierCollectionEnabled: false)
                    .with(preferredUILocaleOverride: AppLanguage.stored().locale.identifier)
            )
        }
        purchases = Purchases.shared
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stream = purchases.customerInfoStream
        updateTask = Task { [weak self] in
            for await info in stream {
                guard !Task.isCancelled, let self else { return }
                self.continuation.yield(self.resolve(info))
            }
        }
    }

    isolated deinit {
        updateTask?.cancel()
        continuation.finish()
    }

    func currentStatus() async throws -> EntitlementStatus {
        do {
            // Revalidate deadlines against RevenueCat instead of accepting a still-fresh SDK cache.
            let info = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)
            let status = resolve(info)
            let migrationKey = "commerce.revenuecat.migrated.\(purchases.appUserID)"
            if !configuration.isTestStore, !status.hasProAccess,
                status != .verificationFailed, !attemptedMigration, !defaults.bool(forKey: migrationKey)
            {
                attemptedMigration = true
                // RevenueCat imports pre-integration Apple purchases without a second transaction observer.
                let migrated = resolve(try await purchases.syncPurchases())
                if migrated != .verificationFailed { defaults.set(true, forKey: migrationKey) }
                return migrated
            }
            return status
        } catch {
            if let cached = purchases.cachedCustomerInfo { return resolve(cached) }
            throw error
        }
    }

    private func resolve(_ info: CustomerInfo) -> EntitlementStatus {
        RevenueCatEntitlementResolver.resolve(info, entitlementID: configuration.entitlementID, now: now())
    }

}
