import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

struct CommerceConfigurationTests {
    @Test
    func normalDebugLaunchUsesLiveCommerce() throws {
        let appFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TFM/App/TermindApp.swift")
        let app = try String(contentsOf: appFile, encoding: .utf8)

        #expect(!app.contains(".developmentDefault()"))
        #expect(app.contains(": .live()"))
    }

    @Test
    func appTargetDeclaresInAppPurchaseCapability() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Termind.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)

        #expect(project.contains("com.apple.InAppPurchase = {"))
    }

    @Test
    func localStoreKitProductMatchesPurchaseRequest() throws {
        let configurationFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "StoreKit/Termind.storekit")
        let data = try Data(contentsOf: configurationFile)
        let configuration = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let products = try #require(configuration["products"] as? [[String: Any]])
        let productIDs = products.compactMap { $0["productID"] as? String }

        #expect(Set(productIDs) == [ProAccessController.lifetimeProductID])
        let pro = try #require(
            products.first { $0["productID"] as? String == ProAccessController.lifetimeProductID })
        #expect(pro["displayPrice"] as? String == "9.99")
        #expect(pro["familyShareable"] as? Bool == true)

        let groups = try #require(configuration["subscriptionGroups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let subscriptions = try #require(group["subscriptions"] as? [[String: Any]])
        let annual = try #require(
            subscriptions.first { $0["productID"] as? String == ProAccessController.annualProductID })
        #expect(annual["displayPrice"] as? String == "3.99")
        #expect(annual["familyShareable"] as? Bool == true)
        #expect(annual["recurringSubscriptionPeriod"] as? String == "P1Y")
        #expect(annual["type"] as? String == "RecurringSubscription")
        let offer = try #require(annual["introductoryOffer"] as? [String: Any])
        #expect(offer["paymentMode"] as? String == "free")
        #expect(offer["subscriptionPeriod"] as? String == "P2W")
    }
}
