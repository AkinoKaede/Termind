import Foundation
import RevenueCat
import TermindDomain
import Testing

@testable import TermindInfrastructure

@Suite(.timeLimit(.minutes(1))) @MainActor
struct RevenueCatCommerceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func testStoreKeyCannotEnableProductionAndWhitespaceIsTrimmed() throws {
        #expect(
            RevenueCatConfiguration(apiKey: "test_example", entitlementID: "termind_pro", allowsTestStore: false) == nil
        )
        let test = try #require(
            RevenueCatConfiguration(apiKey: " test_example \n", entitlementID: "termind_pro", allowsTestStore: true))
        #expect(test.isTestStore)
        #expect(test.apiKey == "test_example")
        #expect(
            RevenueCatConfiguration(
                apiKey: "$(REVENUECAT_API_KEY)", entitlementID: "termind_pro", allowsTestStore: true) == nil)
        #expect(
            RevenueCatConfiguration(apiKey: "sk_private", entitlementID: "termind_pro", allowsTestStore: true) == nil)
        #expect(RevenueCatConfiguration(apiKey: "appl_example", entitlementID: "", allowsTestStore: false) == nil)
        #expect(
            RevenueCatConfiguration(apiKey: "appl_example", entitlementID: "termind_pro", allowsTestStore: false) != nil
        )
    }

    @Test
    func onlyTheConfiguredEntitlementUnlocksPro() throws {
        let info = try customerInfo(entitlementID: "another_entitlement", expiration: now.addingTimeInterval(60))
        #expect(resolve(info) == .free)
    }

    @Test
    func lifetimeAndTestStoreProductIDsAreResolvedThroughTheEntitlement() throws {
        let info = try customerInfo(expiration: nil)
        #expect(resolve(info) == .purchased(.purchased))
    }

    @Test
    func cancelledSubscriptionRetainsAccessUntilExpiryAndFamilyOwnership() throws {
        let info = try customerInfo(
            expiration: now.addingTimeInterval(60), period: "trial", ownership: "FAMILY_SHARED", cancelled: true)
        guard case .subscription(let status) = resolve(info) else {
            Issue.record("Missing subscription")
            return
        }
        #expect(status.phase == .introductoryTrial)
        #expect(status.ownership == .familyShared)
        #expect(status.willAutoRenew == false)
        #expect(status.expiresAt == now.addingTimeInterval(60))
    }

    @Test
    func cachedActiveFlagCannotExtendAnExpiredSubscription() throws {
        let info = try customerInfo(expiration: now.addingTimeInterval(60))
        #expect(info.entitlements.all["termind_pro"]?.isActive == true)
        #expect(
            !RevenueCatEntitlementResolver.resolve(info, entitlementID: "termind_pro", now: now.addingTimeInterval(61))
                .hasProAccess)
    }

    @Test
    func graceUsesItsOwnDeadlineAndBillingRetryDoesNotUnlock() throws {
        let graceEnd = now.addingTimeInterval(120)
        let info = try customerInfo(expiration: now.addingTimeInterval(-60), billingIssue: true, grace: graceEnd)
        guard case .subscription(let status) = resolve(info) else {
            Issue.record("Missing grace")
            return
        }
        #expect(status.phase == .gracePeriod)
        #expect(status.expiresAt == graceEnd)
        let retry = try customerInfo(expiration: now.addingTimeInterval(-60), billingIssue: true)
        #expect(!resolve(retry).hasProAccess)
        #expect(!RevenueCatEntitlementResolver.resolve(info, entitlementID: "termind_pro", now: graceEnd).hasProAccess)
    }

    @Test
    func refundsAndFailedVerificationCannotUnlock() throws {
        #expect(!resolve(try customerInfo(expiration: now.addingTimeInterval(60), refunded: true)).hasProAccess)
        #expect(resolve(try customerInfo(expiration: nil, verification: 2)) == .verificationFailed)
    }

    @Test(arguments: [EntitlementStatus.purchased(.purchased), .free])
    func remotePaywallCompletionUpdatesAccessWithoutClosingItsAccountVariant(status: EntitlementStatus) async {
        let service = FakeService()
        let controller = ProAccessController(purchaseService: service, observeUpdates: false)
        controller.isPaywallPresented = true
        service.status = status
        await controller.completePaywallOperation()
        #expect(controller.status == status)
        #expect(controller.isPaywallPresented)

        service.status = .free
        await controller.refresh()
        #expect(!controller.hasProAccess)
        #expect(controller.isPaywallPresented)
    }

    @Test
    func customerInfoUpdatesGrantAndRevokeAccessWithoutAStoreKitFallback() async {
        let service = FakeService()
        let controller = ProAccessController(purchaseService: service)
        await controller.refresh()
        service.continuation.yield(.purchased(.purchased))
        for _ in 0..<100 where !controller.hasProAccess { await Task.yield() }
        #expect(controller.hasProAccess)
        service.continuation.yield(.free)
        for _ in 0..<100 where controller.hasProAccess { await Task.yield() }
        #expect(!controller.hasProAccess)
    }

    @Test func accessChangesNotifyRuntimeWithoutAVisibleViewOrPaywall() async {
        let service = FakeService()
        let controller = ProAccessController(purchaseService: service, observeUpdates: false)
        var observed: [EntitlementStatus] = []
        controller.accessDidChange = { observed.append(controller.status) }
        defer { controller.accessDidChange = nil }
        await controller.refresh()
        service.status = .purchased(.purchased)
        await controller.refresh()
        service.status = .purchased(.familyShared)
        await controller.refresh()
        service.status = .free
        await controller.refresh()
        #expect(observed == [.free, .purchased(.purchased), .purchased(.familyShared), .free])
        #expect(!controller.isPaywallPresented)
    }

    @Test
    func newerCustomerInfoWinsOverAnOlderRefreshResponse() async {
        let service = FakeService()
        let controller = ProAccessController(purchaseService: service)
        await controller.refresh()
        service.suspendsRefresh = true
        let refresh = Task { await controller.refresh() }
        for _ in 0..<100 where service.refreshContinuation == nil { await Task.yield() }
        #expect(service.refreshContinuation != nil)
        service.continuation.yield(.purchased(.purchased))
        for _ in 0..<100 where !controller.hasProAccess { await Task.yield() }
        #expect(controller.hasProAccess)
        service.refreshContinuation?.resume(returning: .free)
        service.refreshContinuation = nil
        await refresh.value
        #expect(controller.hasProAccess)
    }

    @Test
    func anObsoleteRefreshCannotOverwriteOrDiscardANewerRefresh() async throws {
        let service = FakeService()
        let controller = ProAccessController(purchaseService: service)
        await controller.refresh()
        service.suspendsRefresh = true
        let olderRefresh = Task { await controller.refresh() }
        for _ in 0..<100 where service.refreshContinuation == nil { await Task.yield() }
        let olderResponse = try #require(service.refreshContinuation)
        service.refreshContinuation = nil

        service.continuation.yield(.purchased(.purchased))
        for _ in 0..<100 where !controller.hasProAccess { await Task.yield() }
        #expect(controller.hasProAccess)
        let newerRefresh = Task { await controller.refresh() }
        for _ in 0..<100 where service.refreshContinuation == nil { await Task.yield() }
        let newerResponse = try #require(service.refreshContinuation)
        service.refreshContinuation = nil

        olderResponse.resume(returning: .free)
        await olderRefresh.value
        #expect(controller.hasProAccess)
        newerResponse.resume(returning: .purchased(.familyShared))
        await newerRefresh.value
        #expect(controller.status == .purchased(.familyShared))
    }

    @Test
    func concurrentRefreshesShareOneRevenueCatRequest() async throws {
        let service = FakeService()
        service.suspendsRefresh = true
        let controller = ProAccessController(purchaseService: service, observeUpdates: false)
        let first = Task { await controller.refresh() }
        for _ in 0..<100 where service.refreshContinuation == nil { await Task.yield() }
        let response = try #require(service.refreshContinuation)
        service.refreshContinuation = nil
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await controller.refresh()
        }
        for _ in 0..<100 where !secondStarted { await Task.yield() }
        #expect(secondStarted)
        response.resume(returning: .purchased(.purchased))
        await first.value
        await second.value
        #expect(service.refreshes == 1)
        #expect(controller.hasProAccess)
    }

    @Test
    func anUnavailableServiceDoesNotStartAStoreKitFallback() async {
        let controller = ProAccessController(purchaseService: nil)
        await controller.refresh()
        #expect(!controller.hasProAccess)
        #expect(!controller.usesRevenueCat)
        #expect(controller.status == .verificationFailed)
    }

    @Test
    func aFailedInitialFetchDoesNotLeaveThePaywallLoading() async {
        let service = FakeService()
        service.refreshFails = true
        let controller = ProAccessController(purchaseService: service, observeUpdates: false)
        await controller.refresh()
        #expect(controller.status == .verificationFailed)
        service.refreshFails = false
        service.status = .purchased(.purchased)
        await controller.refresh()
        #expect(controller.hasProAccess)
        service.refreshFails = true
        await controller.refresh()
        #expect(controller.hasProAccess)
    }

    private func resolve(_ info: CustomerInfo) -> EntitlementStatus {
        RevenueCatEntitlementResolver.resolve(info, entitlementID: "termind_pro", now: now)
    }

    private func customerInfo(
        entitlementID: String = "termind_pro", expiration: Date?, period: String = "normal",
        ownership: String = "PURCHASED", cancelled: Bool = false, billingIssue: Bool = false,
        grace: Date? = nil, refunded: Bool = false, verification: Int = 1
    ) throws -> CustomerInfo {
        let formatter = ISO8601DateFormatter()
        let purchase = formatter.string(from: now.addingTimeInterval(-3600))
        let productID = expiration == nil ? "test_lifetime" : "test_annual"
        var product: [String: Any] = [
            "purchase_date": purchase, "original_purchase_date": purchase, "store": "app_store",
            "is_sandbox": true, "period_type": period, "ownership_type": ownership,
        ]
        product["expires_date"] = expiration.map { formatter.string(from: $0) }
        product["unsubscribe_detected_at"] = cancelled ? purchase : nil
        product["billing_issues_detected_at"] = billingIssue ? purchase : nil
        product["grace_period_expires_date"] = grace.map { formatter.string(from: $0) }
        product["refunded_at"] = refunded ? purchase : nil
        var entitlement: [String: Any] = ["product_identifier": productID, "purchase_date": purchase]
        entitlement["expires_date"] = (grace ?? expiration).map { formatter.string(from: $0) }
        let data: [String: Any] = [
            "request_date": formatter.string(from: now), "entitlementVerification": verification,
            "subscriber": [
                "original_app_user_id": "$RCAnonymousID:test", "first_seen": purchase,
                "subscriptions": expiration == nil ? [:] : [productID: product],
                "non_subscriptions": expiration == nil ? [productID: [product]] : [:],
                "entitlements": [entitlementID: entitlement],
            ],
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CustomerInfo.self, from: JSONSerialization.data(withJSONObject: data))
    }

    private final class FakeService: ProPurchaseService {
        let updates: AsyncStream<EntitlementStatus>
        let continuation: AsyncStream<EntitlementStatus>.Continuation
        var status: EntitlementStatus = .free
        var refreshes = 0
        var refreshFails = false
        var suspendsRefresh = false
        var refreshContinuation: CheckedContinuation<EntitlementStatus, Never>?

        init() { (updates, continuation) = AsyncStream.makeStream() }
        func currentStatus() async throws -> EntitlementStatus {
            refreshes += 1
            if refreshFails { throw URLError(.notConnectedToInternet) }
            if suspendsRefresh {
                return await withCheckedContinuation { refreshContinuation = $0 }
            }
            return status
        }
    }
}
