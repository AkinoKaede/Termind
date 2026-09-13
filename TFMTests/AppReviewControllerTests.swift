import Foundation
import TermindApplication
import Testing

@testable import Termind

@Suite
@MainActor
struct AppReviewPresenterTests {
    @Test
    func onlyVaultListsAndAppSettingsAreReviewDestinations() {
        let window = WindowModel(vaultDestination: .hosts)
        #expect(AppReviewPresenter.location(in: window) == .reviewPage("vault.hosts"))
        window.vaultWorkRoute = .hostEditor(nil)
        #expect(AppReviewPresenter.location(in: window) == .other)
        window.vaultWorkRoute = nil
        window.vaultDestination = .welcome
        #expect(AppReviewPresenter.location(in: window) == .other)
        window.selectedDestination = .settings
        #expect(AppReviewPresenter.location(in: window) == .reviewPage("settings"))
        window.settingsRoute = .category(.app)
        #expect(AppReviewPresenter.location(in: window) == .reviewPage("settings.app"))
        window.settingsRoute = .category(.terminal)
        #expect(AppReviewPresenter.location(in: window) == .other)
        window.settingsRoute = .modelProvider(UUID())
        #expect(AppReviewPresenter.location(in: window) == .other)
        for destination in [WindowDestination.assistant, .metrics] {
            window.selectedDestination = destination
            #expect(AppReviewPresenter.location(in: window) == .other)
        }
    }
}
