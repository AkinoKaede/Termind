import Foundation
import StoreKit
import StoreKitTest
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct StoreKitTrialTests {
    @Test
    func freePurchaseRestoresOriginalFourteenDayPeriodAndIgnoresLegacyProof() async throws {
        let fixture = try Fixture()
        fixture.defaults.set(Data("old trial".utf8), forKey: "commerce.pro.trial-proof.v1")
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()
        #expect(access.canStartTrial)
        access.isPaywallPresented = true
        await access.startTrial()
        guard case .trialActive(let expiration) = access.status else {
            Issue.record("Free IAP did not grant a trial: \(access.status), \(String(describing: access.error))")
            return
        }
        #expect(!access.isPaywallPresented)
        #expect(!access.canStartTrial)
        await access.restorePurchases()
        let result = try #require(await Transaction.latest(for: ProAccessController.trialProductID))
        let transaction = try result.payloadValue
        #expect(abs(expiration.timeIntervalSince(transaction.originalPurchaseDate) - ProTrial.duration) < 0.001)
        await access.startTrial()
        #expect(access.status == .trialActive(expiresAt: expiration))
        let restored = fixture.controller()
        await restored.restorePurchases()
        #expect(restored.status == access.status)
        #expect(restored.error == nil)
    }

    @Test
    func expiryAndClockRollbackPreserveOnlyExistingWorkspaceAccess() async throws {
        let fixture = try Fixture()
        let transaction = try await fixture.session.buyProduct(identifier: ProAccessController.trialProductID)
        var date = transaction.originalPurchaseDate.addingTimeInterval(7 * 86_400)
        let access = fixture.controller(now: { date })
        await access.refresh()
        #expect(access.hasProAccess)
        guard case .trialActive(let expiration) = access.status else {
            Issue.record("Expected an active trial")
            return
        }
        date = expiration
        await access.refresh()
        #expect(access.status == .trialExpired)
        #expect(access.canUse(.workspaceComposition))
        #expect(!access.canUse(.assistant))
        date = transaction.originalPurchaseDate
        let relaunched = fixture.controller(now: { date })
        await relaunched.restorePurchases()
        #expect(relaunched.status == .trialExpired)
        #expect(relaunched.error == .trialAlreadyUsed)
        #expect(!relaunched.canUse(.workspaceComposition))
    }

    @Test
    func revokedTrialRemainsClaimedAndLifetimePurchaseTakesPrecedence() async throws {
        let fixture = try Fixture()
        let transaction = try await fixture.session.buyProduct(identifier: ProAccessController.trialProductID)
        try fixture.session.refundTransaction(identifier: UInt(transaction.id))
        let access = fixture.controller()
        await access.refresh()
        #expect(access.status == .trialExpired)
        await access.startTrial()
        #expect(access.error == .trialAlreadyUsed)
        await access.purchase()
        #expect(access.status == .purchased(.purchased))
        #expect(!access.canStartTrial)
        #expect(!access.canPurchase)
    }

    @Test
    func cancellationAndNetworkFailuresDoNotRemoveActiveTrial() async throws {
        let fixture = try Fixture()
        try await fixture.session.buyProduct(identifier: ProAccessController.trialProductID)
        let access = fixture.controller()
        await access.refresh()
        let active = access.status
        try await fixture.session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await access.purchase()
        #expect(access.status == active)
        #expect(!access.isProcessing)
        #expect(access.error == nil)
        try await fixture.session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        await access.purchase()
        #expect(access.status == active)
        #expect(access.error != nil)
        try await fixture.session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await access.reloadProducts()
        #expect(access.status == active)
        #expect(access.product == nil)
        #expect(access.message != nil)
        try await fixture.session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        await access.restorePurchases()
        #expect(access.status == active)
    }

    @Test
    func pendingApprovalBlocksRepeatedTrialAndVerifiedUpdateCompletesAccess() async throws {
        let fixture = try Fixture()
        fixture.session.askToBuyEnabled = true
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()
        let first = Task { await access.startTrial() }
        await Task.yield()
        await access.startTrial()
        await first.value
        #expect(access.pendingProductID == ProAccessController.trialProductID)
        #expect(access.status == .free(trialAvailable: true))
        #expect(!access.canStartTrial)
        let transactions = fixture.session.allTransactions()
        #expect(transactions.count == 1)
        let pending = try #require(transactions.first)
        try fixture.session.approveAskToBuyTransaction(identifier: pending.identifier)
        // The macOS hosted test runner may expose approval in history without
        // pushing Transaction.updates. Exercise the production observer handler
        // with that actual verified StoreKit result; Sandbox covers push delivery.
        var approvedResult: VerificationResult<Transaction>?
        for _ in 0..<100 where approvedResult == nil {
            approvedResult = await Transaction.latest(for: ProAccessController.trialProductID)
            if approvedResult == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let approved = try #require(approvedResult)
        await access.handleTransactionUpdate(approved)
        #expect(access.hasProAccess)
        #expect(access.pendingProductID == nil)
    }

    @Test
    func timerExpiresTrialWithoutAnotherUserAction() async throws {
        let fixture = try Fixture()
        try await fixture.session.buyProduct(
            identifier: ProAccessController.trialProductID,
            options: [.purchaseDate(Date.now.addingTimeInterval(-ProTrial.duration + 1))]
        )
        let access = fixture.controller()
        await access.refresh()
        #expect(access.hasProAccess)
        for _ in 0..<60 where access.status != .trialExpired {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(access.status == .trialExpired)
        #expect(access.canUse(.workspaceComposition))
        #expect(!access.canUse(.assistant))
    }

    @Test
    func unverifiedHistoryCannotGrantTrialOrOfferAnotherClaim() async throws {
        let fixture = try Fixture()
        try await fixture.session.buyProduct(identifier: ProAccessController.trialProductID)
        try await fixture.session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        let access = fixture.controller()
        await access.refresh()
        #expect(access.status == .verificationFailed)
        await access.startTrial()
        #expect(access.error == .purchaseVerificationFailed)
        #expect(!access.hasProAccess)
    }

    @Test(arguments: ["paid", "consumable", "shared", "missing", "missingPro"])
    func invalidProductConfigurationNeverStartsTrial(configuration: String) async throws {
        let url = try Fixture.modifiedConfiguration(configuration)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try Fixture(configuration: url)
        let access = fixture.controller()
        await access.refresh()
        await access.reloadProducts()
        #expect(!access.canStartTrial)
        await access.startTrial()
        #expect(!access.hasProAccess)
        #expect(access.error != nil)
        #expect(fixture.session.allTransactions().isEmpty)
    }

    @Test
    func restoringAnAccountWithoutPurchasesReportsNoPurchase() async throws {
        let fixture = try Fixture()
        let access = fixture.controller()
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
        let suite = "StoreKitTrialTests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init(configuration: URL = configurationURL) throws {
            session = try SKTestSession(contentsOf: configuration)
            session.resetToDefaultState()
            session.disableDialogs = true
            session.clearTransactions()
            defaults = UserDefaults(suiteName: suite)!
        }

        isolated deinit {
            session.clearTransactions()
            session.resetToDefaultState()
            defaults.removePersistentDomain(forName: suite)
        }

        func controller(now: @escaping () -> Date = { .now }) -> ProAccessController {
            ProAccessController(defaults: defaults, now: now, observeStore: false)
        }

        static func modifiedConfiguration(_ name: String) throws -> URL {
            var root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL)) as? [String: Any])
            var products = try #require(root["products"] as? [[String: Any]])
            let index = try #require(
                products.firstIndex { $0["productID"] as? String == ProAccessController.trialProductID })
            switch name {
            case "paid": products[index]["displayPrice"] = "1.99"
            case "consumable": products[index]["type"] = "Consumable"
            case "shared": products[index]["familyShareable"] = true
            case "missing": products.remove(at: index)
            case "missingPro": products = [products[index]]
            default: preconditionFailure("Unknown test configuration")
            }
            root["products"] = products
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).storekit")
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            return url
        }
    }
}
