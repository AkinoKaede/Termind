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

    @Test @MainActor
    func reviewDemoCodeOnlySimulatesExpiredAccess() {
        let suiteName = "CommerceConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let access = ProAccessController.testing(
            status: .trialActive(expiresAt: .distantFuture),
            reviewDefaults: defaults
        )

        #expect(!access.activateReviewDemo(using: "incorrect"))
        #expect(access.hasProAccess)
        #expect(access.activateReviewDemo(using: " termind-review-2026 "))
        #expect(access.status == .trialExpired)
        #expect(!access.hasProAccess)
        #expect(ProFeature.allCases.allSatisfy { !access.canUse($0) })
        #expect(access.isReviewDemoModeEnabled)

        let relaunched = ProAccessController.testing(
            status: .free(trialAvailable: true),
            reviewDefaults: defaults
        )
        #expect(relaunched.isReviewDemoModeEnabled)
    }

    @Test
    func reviewDemoControlsStayHiddenUntilExplicitlyUnlocked() throws {
        let paywallFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TFM/Features/Commerce/ProPaywallView.swift")
        let paywall = try String(contentsOf: paywallFile, encoding: .utf8)

        #expect(paywall.contains(".onTapGesture(count: 7)"))
        #expect(paywall.contains("if isReviewDemoUnlocked || pro.isReviewDemoModeEnabled"))
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

        #expect(Set(productIDs) == [ProAccessController.productID, ProAccessController.trialProductID])
        let trial = try #require(products.first { $0["productID"] as? String == ProAccessController.trialProductID })
        #expect(trial["displayPrice"] as? String == "0")
        #expect(trial["type"] as? String == "NonConsumable")
        #expect(trial["familyShareable"] as? Bool == false)
        let pro = try #require(products.first { $0["productID"] as? String == ProAccessController.productID })
        #expect(pro["familyShareable"] as? Bool == true)
    }
}
