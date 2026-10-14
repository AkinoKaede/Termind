import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct AppReviewInvitationTests {
    @Test(arguments: [false, true])
    func storeLinkRecordsOnlyAcceptedOpens(accepted: Bool) async throws {
        let controller = AppReviewController(isEnabled: true)
        var openedURLs: [URL] = []
        let openURL = OpenURLAction { url in
            openedURLs.append(url)
            return accepted ? .handled : .discarded
        }
        controller.openReview { url, completion in
            openURL(url, completion: completion)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(openedURLs == [AppReviewController.reviewURL])
        #expect(controller.response == (accepted ? .openedReview : nil))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 800.0])
    func invitationRendersWithoutActivatingAWindowOrChangingPreference(language: String, width: Double) throws {
        let controller = AppReviewController()
        let hosting = NSHostingView(
            rootView: AppReviewInvitationView(controller: controller)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .light)
                .frame(width: width)
                .background(.background))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width <= width)
        #expect(controller.response == nil)
        #expect(!controller.isPreviewEnabled)
        if ProcessInfo.processInfo.environment["TERMIND_REVIEW_PREVIEW"] == "1" {
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(png, named: "termind-review-macos-\(language)-\(Int(width)).png")
        }
    }

    @Test
    func invitationAreaIsNotBlankCanvas() {
        let invitation = CGRect(x: 24, y: 24, width: 600, height: 100)
        #expect(
            !CardMarqueeSelectionResolver.isBlank(
                CGPoint(x: 500, y: 75), cardFrames: [], interactiveFrames: [invitation]))
        #expect(
            CardMarqueeSelectionResolver.isBlank(
                CGPoint(x: 500, y: 140), cardFrames: [], interactiveFrames: [invitation]))
    }

}
