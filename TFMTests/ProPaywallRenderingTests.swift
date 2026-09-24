import AppKit
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

/// Offscreen fixtures exercise shared content without contacting StoreKit or activating a window.
@Suite(.serialized) @MainActor
struct ProPaywallRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func sharedContentFitsThePlatformAndLargerText(language: String, largeText: Bool) async throws {
        let sizes = [CGSize(width: 604, height: 640)]
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
                    canStartTrial: !subscribed, canPurchaseAnnual: !subscribed, canPurchaseLifetime: !subscribed,
                    supportsMCPServer: true)
                let content = ProPaywallContent(
                    presentation: presentation, selectedPlan: .constant(.annual),
                    background: Color(nsColor: .windowBackgroundColor),
                    cardBackground: Color(nsColor: .controlBackgroundColor), purchase: { _ in },
                    restorePurchases: {}, reloadProducts: {}, manageSubscription: {}
                )
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
                .frame(width: size.width, height: size.height)
                .background(.background)
                let name = "pro-\(language)-\(Int(size.width))-\(largeText ? "large" : "regular")-\(subscribed).png"
                let host = NSHostingView(rootView: content)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
                let document = try #require(scroll.documentView)
                #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
                #expect(scroll.contentView.bounds.height > 100)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                Attachment.record(data, named: name)
                let directory = FileManager.default.temporaryDirectory.appending(path: "termind-pro-previews")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appending(path: name))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
