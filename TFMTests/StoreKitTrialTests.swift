import Foundation
import StoreKit
import StoreKitTest
import Testing

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_STOREKIT_TESTS"] == "1",
        "Set TERMIND_STOREKIT_TESTS=1 to run StoreKit tests that require manual authorization"),
    .serialized)
@MainActor
struct StoreKitTrialTests {
    // This local fixture validates catalog metadata only. RevenueCatCommerceTests covers app access.
    @Test
    func fixtureHasTheUniversalAnnualAndLifetimeProductsWithAFreeIntroOffer() async throws {
        let configuration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "StoreKit/Termind.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        defer { session.resetToDefaultState() }

        let products = try await Product.products(
            for: ["com.akinokaede.termind.pro.annual", "com.akinokaede.termind.pro"])
        let annual = try #require(products.first { $0.id == "com.akinokaede.termind.pro.annual" })
        let lifetime = try #require(products.first { $0.id == "com.akinokaede.termind.pro" })
        #expect(annual.type == .autoRenewable)
        #expect(annual.isFamilyShareable)
        #expect(lifetime.type == .nonConsumable)
        #expect(lifetime.isFamilyShareable)
        let subscription = try #require(annual.subscription)
        #expect(subscription.subscriptionPeriod.unit == .year)
        #expect(subscription.subscriptionPeriod.value == 1)
        let offer = try #require(subscription.introductoryOffer)
        #expect(offer.paymentMode == .freeTrial)
        #expect(offer.price == .zero)
        #expect(offer.period.unit == .week)
        #expect(offer.period.value * offer.periodCount == 2)
    }
}
