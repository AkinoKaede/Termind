import RevenueCat
import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS
@testable import TermindInfrastructure

/// Holds an isolated host list for an actual Simulator long-press and screenshot.
@Suite(
    .requiresKeyWindow,
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_HOST_WAKE_UI_REVIEW"] == "1"),
    .serialized)
@MainActor
struct MobileHostWakeUIReviewTests {
    @Test(.timeLimit(.minutes(2))) func lockedWakeMenuAndPaywallForManualReview() async throws {
        if !Purchases.isConfigured, let configuration = RevenueCatConfiguration.bundled() {
            Purchases.configure(
                with: Configuration.builder(withAPIKey: configuration.apiKey)
                    .with(storeKitVersion: .storeKit2)
                    .with(automaticDeviceIdentifierCollectionEnabled: false)
                    .with(preferredUILocaleOverride: "en"))
        }
        let pro = ProAccessController(purchaseService: WakeReviewPurchaseService(), observeUpdates: false)
        await pro.refresh()
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = pro
        let app = try MobileAppModel(dependencies: dependencies)
        defer {
            app.metrics.core.shutdown()
            app.outbox.stop()
        }
        app.library.hostAccess.entitlement = .unrestrictedForTesting
        for name in ["Production", "Staging", "Database", "Backup"] {
            var host = TermindDomain.Host(name: name, host: "\(name.lowercased()).example.invalid")
            host.wakeOnLAN = .init(macAddress: "00:1A:2B:3C:4D:5E")
            app.library.upsert(host)
        }
        app.library.hostAccess.entitlement = .free
        app.library.wakeOnLAN = WakeOnLANController(sender: UnexpectedReviewWakeSender())
        let backup = try #require(app.library.hosts.first(where: { $0.name == "Backup" }))
        #expect(app.library.isLocked(backup))
        let model = MobileSceneModel(app: app, sessionID: "wake-paywall-review")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: MobileRootView(app: app, scene: model).environment(\.locale, Locale(identifier: "en")))
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .seconds(1))
        if let scroll = descendants(window).compactMap({ $0 as? UIScrollView })
            .first(where: { $0.contentSize.height > $0.bounds.height + 100 })
        {
            scroll.setContentOffset(
                CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom),
                animated: false)
        }
        try await Task.sleep(for: .seconds(1))
        print("TERMIND_MOBILE_WAKE_REVIEW_READY")
        fflush(nil)
        for _ in 0..<180 where !app.pro.isPaywallPresented { try await Task.sleep(for: .milliseconds(500)) }
        try #require(app.pro.isPaywallPresented, "Long-press Backup and tap Wake during the manual review hold")
        try await Task.sleep(for: .seconds(8))
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let filename = "iphone-host-access-wake-paywall-en.png"
        Attachment.record(data, named: filename)
        let path = FileManager.default.temporaryDirectory.appending(path: filename)
        try data.write(to: path)
        print("TERMIND_MOBILE_HOST_ACCESS_REVIEW|\(path.path)")
        #expect(model.editingHost == nil)
        #expect(app.workspaces.isEmpty)
    }

}

@MainActor
private final class WakeReviewPurchaseService: ProPurchaseService {
    var updates: AsyncStream<EntitlementStatus> { AsyncStream { $0.finish() } }
    func currentStatus() async throws -> EntitlementStatus { .free }
}

private nonisolated struct UnexpectedReviewWakeSender: WakeOnLANSending {
    func send(to address: MACAddress) throws { Issue.record("A locked host must not send a Wake packet") }
}
