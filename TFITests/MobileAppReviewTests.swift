import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileAppReviewTests {
    @Test
    func testModelsDisableInvitationsAndShareAnInjectedController() throws {
        let disabled = try MobileAppModel(inMemory: true)
        #expect(!disabled.appReview.isEnabled)
        let injected = AppReviewController(isEnabled: true)
        let app = try MobileAppModel(inMemory: true, appReview: injected)
        #expect(app.appReview === injected)
        app.appReview.setPreviewEnabled(true)
        #expect(injected.isPreviewEnabled)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 430.0, 768.0])
    func invitationFitsPhoneAndTabletWidths(language: String, width: Double) throws {
        let controller = AppReviewController()
        let variants: [(ColorScheme, DynamicTypeSize, String)] = [
            (.light, .large, "standard"), (.dark, .accessibility3, "accessible"),
        ]
        var standardHeight = 0
        for (scheme, typeSize, name) in variants {
            let content = AppReviewInvitationView(controller: controller)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
                .frame(width: width)
                .background(scheme == .light ? Color.white : Color.black)
            let renderer = ImageRenderer(content: content)
            let image = try #require(renderer.cgImage)
            if name == "standard" {
                standardHeight = image.height
            } else {
                #expect(image.height > standardHeight)
            }
            #expect(controller.response == nil)
            if ProcessInfo.processInfo.environment["TERMIND_REVIEW_PREVIEW"] == "1" {
                let png = try #require(UIImage(cgImage: image).pngData())
                Attachment.record(png, named: "termind-review-ios-\(language)-\(Int(width))-\(name).png")
            }
        }
    }
}
