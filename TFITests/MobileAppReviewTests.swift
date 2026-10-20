// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import Testing

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

}
