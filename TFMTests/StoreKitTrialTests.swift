import Foundation
import StoreKit
import StoreKitTest
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct StoreKitTrialTests {
    @Test
    func annualProductSuppliesPriceBillingPeriodTrialDurationAndEntitlement() async throws {
        let fixture = try Fixture()
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()

        #expect(access.annualProduct?.displayPrice == "$3.99")
        #expect(access.displayPrice == "$9.99")
        #expect(access.annualBillingPeriod?.year == 1)
        #expect(access.annualIntroOfferDuration?.weekOfYear == 2)
        #expect(access.canStartTrial)

        access.isPaywallPresented = true
        await access.purchaseAnnual()
        guard case .subscription(let subscription) = access.status else {
            Issue.record("Annual purchase did not produce subscription access: \(access.status)")
            return
        }
        #expect(subscription.phase == .introductoryTrial)
        #expect(subscription.expiresAt != nil)
        #expect(access.hasProAccess)
        #expect(!access.isPaywallPresented)
        #expect(!access.canPurchaseAnnual)
        #expect(!access.canPurchase)

        let relaunched = fixture.controller()
        await relaunched.reloadProducts()
        await relaunched.restorePurchases()
        #expect(relaunched.status.hasProAccess)
        #expect(relaunched.error == nil)
    }

    @Test
    func lifetimePurchaseTakesPrecedenceOverAnnualSubscription() async throws {
        let fixture = try Fixture()
        try await fixture.session.buyProduct(identifier: ProAccessController.annualProductID)
        try await fixture.session.buyProduct(identifier: ProAccessController.lifetimeProductID)
        let access = fixture.controller()
        await access.refresh()

        #expect(access.status == .purchased(.purchased))
        #expect(access.hasProAccess)
        #expect(!access.status.canPurchase)
    }

    @Test
    func cancellationAndNetworkFailuresDoNotRemoveAnnualAccess() async throws {
        let fixture = try Fixture()
        try await fixture.session.buyProduct(identifier: ProAccessController.annualProductID)
        let access = fixture.controller()
        await access.refresh()
        let active = access.status

        try await fixture.session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await access.purchaseAnnual()
        #expect(access.status == active)
        #expect(access.error == nil)
        try await fixture.session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await access.reloadProducts()
        #expect(access.status == active)
        #expect(access.message == nil)
    }

    @Test
    func pendingAnnualPurchaseBlocksRepeatedRequestsAndVerifiedUpdateCompletesAccess() async throws {
        let fixture = try Fixture()
        fixture.session.askToBuyEnabled = true
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()

        let first = Task { await access.purchaseAnnual() }
        await Task.yield()
        await access.purchaseAnnual()
        await first.value
        #expect(access.pendingProductID == ProAccessController.annualProductID)
        #expect(!access.canPurchaseAnnual)
        #expect(fixture.session.allTransactions().count == 1)

        let pending = try #require(fixture.session.allTransactions().first)
        try fixture.session.approveAskToBuyTransaction(identifier: pending.identifier)
        var approved: VerificationResult<Transaction>?
        for _ in 0..<100 where approved == nil {
            approved = await Transaction.latest(for: ProAccessController.annualProductID)
            if approved == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        await access.handleTransactionUpdate(try #require(approved))
        #expect(access.hasProAccess)
        #expect(access.pendingProductID == nil)
    }

    @Test
    func unverifiedAnnualTransactionNeverGrantsAccess() async throws {
        let fixture = try Fixture()
        try await fixture.session.buyProduct(identifier: ProAccessController.annualProductID)
        try await fixture.session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        let access = fixture.controller()
        await access.refresh()

        #expect(access.status == .verificationFailed)
        #expect(!access.hasProAccess)
    }

    @Test
    func annualRemainsPurchasableWhenTheIntroductoryOfferIsRemoved() async throws {
        let url = try Fixture.modifiedConfiguration("missingOffer")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try Fixture(configuration: url)
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()

        #expect(access.canPurchaseAnnual)
        #expect(!access.canStartTrial)
        #expect(access.annualIntroOfferDuration == nil)
        await access.purchaseAnnual()
        guard case .subscription(let subscription) = access.status else {
            Issue.record("Annual purchase without a trial did not produce subscription access")
            return
        }
        #expect(subscription.phase == .subscribed)
        #expect(subscription.expiresAt != nil)
    }

    @Test(arguments: ["monthly", "unshared", "missingAnnual"])
    func invalidAnnualConfigurationCannotBePurchased(configuration: String) async throws {
        let url = try Fixture.modifiedConfiguration(configuration)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try Fixture(configuration: url)
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()

        #expect(!access.canPurchaseAnnual)
        #expect(!access.canStartTrial)
        #expect(access.canPurchase)
        await access.purchaseAnnual()
        #expect(!access.hasProAccess)
        #expect(fixture.session.allTransactions().isEmpty)
    }

    @Test
    func restoringAnAccountWithoutPurchasesReportsNoActivePurchase() async throws {
        let fixture = try Fixture()
        let access = fixture.controller()
        await access.reloadProducts()
        await access.restorePurchases()

        #expect(access.status == .free(trialAvailable: true))
        #expect(access.error == .purchaseNotFound)
    }

    private final class Fixture {
        static var configurationURL: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "StoreKit/Termind.storekit")
        }

        let session: SKTestSession

        init(configuration: URL = configurationURL) throws {
            session = try SKTestSession(contentsOf: configuration)
            session.resetToDefaultState()
            session.disableDialogs = true
            session.clearTransactions()
        }

        isolated deinit {
            session.clearTransactions()
            session.resetToDefaultState()
        }

        func controller(now: @escaping () -> Date = { .now }) -> ProAccessController {
            ProAccessController(now: now, observeStore: false)
        }

        static func modifiedConfiguration(_ name: String) throws -> URL {
            var root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL)) as? [String: Any])
            var groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
            var subscriptions = try #require(groups[0]["subscriptions"] as? [[String: Any]])
            let index = try #require(
                subscriptions.firstIndex { $0["productID"] as? String == ProAccessController.annualProductID })
            switch name {
            case "monthly": subscriptions[index]["recurringSubscriptionPeriod"] = "P1M"
            case "unshared": subscriptions[index]["familyShareable"] = false
            case "missingOffer": subscriptions[index]["introductoryOffer"] = NSNull()
            case "missingAnnual": subscriptions.remove(at: index)
            default: preconditionFailure("Unknown test configuration")
            }
            groups[0]["subscriptions"] = subscriptions
            root["subscriptionGroups"] = groups
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).storekit")
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            return url
        }
    }
}
