import SwiftUI
import TermindDomain
import TermindPresentation
import Testing
import UIKit

/// Native fixtures use the app's localized resources without contacting StoreKit.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
        "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"),
    .serialized) @MainActor
struct ProPaywallRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func sharedContentFitsThePlatformAndLargerText(language: String, largeText: Bool) async throws {
        let sizes = [CGSize(width: 375, height: 760), CGSize(width: 700, height: 850)]
        for size in sizes {
            for subscribed in [false, true] {
                let status: EntitlementStatus =
                    subscribed
                    ? .subscription(
                        ProSubscriptionStatus(
                            phase: .subscribed, expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                            willAutoRenew: false, ownership: .purchased))
                    : .free(trialAvailable: true)
                let presentation = ProPaywallPresentation(
                    status: status, annualPrice: "$19.99", lifetimePrice: "$49.99",
                    billingPeriod: DateComponents(year: 1), trialDuration: DateComponents(weekOfYear: 2),
                    canStartTrial: !subscribed, canPurchaseAnnual: !subscribed, canPurchaseLifetime: !subscribed)
                let content = ProPaywallContent(
                    presentation: presentation, selectedPlan: .constant(.annual),
                    background: Color(uiColor: .systemGroupedBackground),
                    cardBackground: Color(uiColor: .secondarySystemGroupedBackground), purchase: { _ in },
                    restorePurchases: {}, reloadProducts: {}, manageSubscription: {}
                )
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
                .background(.background)
                let name = "pro-\(language)-\(Int(size.width))-\(largeText ? "large" : "regular")-\(subscribed).png"
                let host = UIHostingController(rootView: content)
                host.loadViewIfNeeded()
                let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?
                    .keyWindow
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previousWindow?.makeKey()
                }
                _ = host.sizeThatFits(in: size)
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.view.layoutIfNeeded()
                let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
                #expect(scroll.contentSize.width <= scroll.bounds.width + 1)
                #expect(scroll.bounds.height > 100)
                if largeText {
                    scroll.setContentOffset(
                        CGPoint(
                            x: 0,
                            y: max(
                                0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                            )),
                        animated: false)
                    host.view.layoutIfNeeded()
                }
                let data = UIGraphicsImageRenderer(size: size).pngData { context in
                    host.view.layer.render(in: context.cgContext)
                }
                Attachment.record(data, named: name)
                let directory = FileManager.default.temporaryDirectory.appending(path: "termind-pro-previews")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appending(path: name))
            }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
