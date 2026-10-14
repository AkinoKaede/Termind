import Foundation
import Testing

@testable import TermindApplication

@Suite @MainActor
struct AppReviewControllerTests {
    @Test
    func startsAtFirstLaunchAndRequiresSevenElapsedDaysAndAHost() throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        #expect(h.defaults.object(forKey: SettingsKey.reviewFirstUse) as? Date == h.date)
        h.date.addTimeInterval(7 * 86_400 - 1)
        #expect(!controller.isEligible(hasHosts: true))
        h.date.addTimeInterval(1)
        #expect(controller.isEligible(hasHosts: true))
        #expect(!controller.isEligible(hasHosts: false))
    }

    @Test
    func reopeningPreservesFirstUseAndIgnoresLegacyAttemptBudgets() throws {
        let h = try Harness()
        defer { h.clear() }
        _ = h.makeController()
        let firstUse = h.date
        h.date.addTimeInterval(8 * 86_400)
        h.defaults.set(h.date, forKey: "app.review.lastAttempt")
        h.defaults.set(["1.0"], forKey: "app.review.requestedVersions")
        h.defaults.set(["one-day"], forKey: "app.review.activeDays")
        let controller = h.makeController()
        #expect(controller.isEligible(hasHosts: true))
        #expect(h.defaults.object(forKey: SettingsKey.reviewFirstUse) as? Date == firstUse)
    }

    @Test(arguments: [false, true])
    func bothResponsesSurviveRelaunchAndDoNotClaimACompletedRating(opened: Bool) throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        h.date.addTimeInterval(8 * 86_400)
        if opened { controller.openReview { _, completion in completion(true) } } else { controller.decline() }
        h.date.addTimeInterval(366 * 86_400)
        let restored = h.makeController()
        #expect(restored.response == (opened ? .openedReview : .declined))
        #expect(!restored.isEligible(hasHosts: true))
    }

    @Test
    func aRejectedURLOpenDoesNotConsumeTheInvitation() throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        h.date.addTimeInterval(8 * 86_400)
        controller.openReview { _, completion in completion(false) }
        #expect(controller.response == nil)
        #expect(controller.isEligible(hasHosts: true))
        #expect(h.defaults.object(forKey: SettingsKey.reviewInvitationResponse) == nil)
    }

    @Test
    func timeAndNewHostsDoNotInsertAnInvitationUntilTheNextVisit() throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        var visit = AppReviewInvitationVisit()
        visit.enter(controller: controller, hasHosts: true)
        h.date.addTimeInterval(8 * 86_400)
        #expect(!visit.isVisible(controller: controller, hasHosts: true, isFiltering: false))
        visit.enter(controller: controller, hasHosts: false)
        #expect(!visit.isVisible(controller: controller, hasHosts: true, isFiltering: false))
        visit.enter(controller: controller, hasHosts: true)
        #expect(visit.isVisible(controller: controller, hasHosts: true, isFiltering: false))
    }

    @Test(arguments: [false, true])
    func allWindowsHideImmediatelyAfterEitherResponse(opened: Bool) throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        h.date.addTimeInterval(8 * 86_400)
        var first = AppReviewInvitationVisit()
        var second = AppReviewInvitationVisit()
        first.enter(controller: controller, hasHosts: true)
        second.enter(controller: controller, hasHosts: true)
        #expect(first.isVisible(controller: controller, hasHosts: true, isFiltering: false))
        #expect(second.isVisible(controller: controller, hasHosts: true, isFiltering: false))
        if opened { controller.openReview { _, completion in completion(true) } } else { controller.decline() }
        #expect(!first.isVisible(controller: controller, hasHosts: true, isFiltering: false))
        #expect(!second.isVisible(controller: controller, hasHosts: true, isFiltering: false))
    }

    @Test
    func filteringAndDeletingTheLastHostHideWithoutConsumingTheInvitation() throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        h.date.addTimeInterval(8 * 86_400)
        var visit = AppReviewInvitationVisit()
        visit.enter(controller: controller, hasHosts: true)
        #expect(!visit.isVisible(controller: controller, hasHosts: true, isFiltering: true))
        #expect(!visit.isVisible(controller: controller, hasHosts: false, isFiltering: false))
        #expect(visit.isVisible(controller: controller, hasHosts: true, isFiltering: false))
        #expect(controller.response == nil)
    }

    @Test(arguments: [false, true])
    func developerSwitchBypassesGatesAndNeverChangesTheRealResponse(opened: Bool) throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        controller.decline()
        var visit = AppReviewInvitationVisit()
        visit.enter(controller: controller, hasHosts: false)
        controller.setPreviewEnabled(true)
        #expect(visit.isVisible(controller: controller, hasHosts: false, isFiltering: false))
        #expect(!visit.isVisible(controller: controller, hasHosts: false, isFiltering: true))
        if opened {
            controller.openReview { _, _ in Issue.record("Developer preview must not open external URLs.") }
        } else {
            controller.decline()
        }
        #expect(!visit.isVisible(controller: controller, hasHosts: false, isFiltering: false))
        #expect(controller.response == .declined)
        #expect(h.makeController().response == .declined)
        #expect(!h.makeController().isPreviewEnabled)
        controller.setPreviewEnabled(false)
        controller.setPreviewEnabled(true)
        #expect(visit.isVisible(controller: controller, hasHosts: false, isFiltering: false))
        controller.setPreviewEnabled(false)
        #expect(!visit.isVisible(controller: controller, hasHosts: false, isFiltering: false))
    }

    @Test
    func disabledControllersLeaveDefaultsUntouched() throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = AppReviewController(defaults: h.defaults, now: { h.date })
        h.date.addTimeInterval(8 * 86_400)
        controller.decline()
        controller.openReview { _, completion in completion(true) }
        #expect(!controller.isEligible(hasHosts: true))
        #expect(h.defaults.object(forKey: SettingsKey.reviewFirstUse) == nil)
        #expect(h.defaults.object(forKey: SettingsKey.reviewInvitationResponse) == nil)
    }

    @Test
    func clockRollbackDoesNotMakeANewInstallationEligible() throws {
        let h = try Harness()
        defer { h.clear() }
        let controller = h.makeController()
        h.date.addTimeInterval(-86_400)
        #expect(!controller.isEligible(hasHosts: true))
    }

    private final class Harness {
        let suite = "AppReviewControllerTests.\(UUID())"
        let defaults: UserDefaults
        var date = Date(timeIntervalSince1970: 1_735_689_600)

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func makeController() -> AppReviewController {
            AppReviewController(defaults: defaults, isEnabled: true, now: { [unowned self] in self.date })
        }

        func clear() {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
