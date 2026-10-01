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
    func localStoreKitFixtureContainsAnnualAndLifetimeProducts() throws {
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

        #expect(Set(productIDs) == ["com.akinokaede.termind.pro"])
        let pro = try #require(
            products.first { $0["productID"] as? String == "com.akinokaede.termind.pro" })
        #expect(pro["displayPrice"] as? String == "9.99")
        #expect(pro["familyShareable"] as? Bool == true)

        let groups = try #require(configuration["subscriptionGroups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let subscriptions = try #require(group["subscriptions"] as? [[String: Any]])
        let annual = try #require(
            subscriptions.first { $0["productID"] as? String == "com.akinokaede.termind.pro.annual" })
        #expect(annual["displayPrice"] as? String == "3.99")
        #expect(annual["familyShareable"] as? Bool == true)
        #expect(annual["recurringSubscriptionPeriod"] as? String == "P1Y")
        #expect(annual["type"] as? String == "RecurringSubscription")
        let offer = try #require(annual["introductoryOffer"] as? [String: Any])
        #expect(offer["paymentMode"] as? String == "free")
        #expect(offer["subscriptionPeriod"] as? String == "P2W")
    }
}
