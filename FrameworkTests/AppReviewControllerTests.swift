import Foundation
import Testing

@testable import TermindApplication

@Suite
@MainActor
struct AppReviewControllerTests {
    @Test
    func firstUseRequiresSevenElapsedDaysAndThreeDistinctActiveDates() throws {
        let h = try Harness()
        defer { h.clear() }
        h.update(.reviewPage("vault.hosts"))
        h.advance(86_400)
        h.update(.reviewPage("vault.hosts"))
        h.update(.reviewPage("vault.hosts"))
        #expect(h.activeDays == 2)
        h.date = h.firstDate.addingTimeInterval(7 * 86_400 - 301)
        h.work(for: 300)
        h.finish()
        #expect(h.requests == 0)
        #expect(h.activeDays == 3)
        h.date = h.firstDate.addingTimeInterval(7 * 86_400)
        h.work(for: 0)
        h.finish()
        #expect(h.requests == 1)
    }

    @Test
    func calendarAgeAloneDoesNotReplaceActiveDays() throws {
        let h = try Harness()
        defer { h.clear() }
        h.update(.reviewPage("vault.hosts"))
        h.advance(8 * 86_400)
        h.work(for: 300)
        h.finish()
        #expect(h.activeDays == 2)
        #expect(h.requests == 0)
    }

    @Test
    func fiveMinutesOnlyCountsForegroundWorkspaceTime() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 299)
        h.update(.workspace(h.workspaceID), active: false)
        h.advance(3_600)
        h.update(.workspace(h.workspaceID))
        h.finish()
        #expect(h.requests == 0)
        h.work(for: 1)
        h.finish()
        #expect(h.requests == 1)
    }

    @Test
    func eligibleReturnWaitsThreeSecondsAndRecordsBeforeCallingStoreKit() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 300)
        h.update(.reviewPage("settings"))
        h.advance(2.999)
        h.request()
        #expect(h.requests == 0)
        h.advance(0.001)
        h.controller.requestIfReady(surfaceID: h.surfaceID) {
            #expect(h.defaults.stringArray(forKey: SettingsKey.reviewRequestedVersions) == ["1.0"])
            #expect(h.defaults.object(forKey: SettingsKey.reviewLastAttempt) as? Date == h.date)
            h.requests += 1
        }
        h.request()
        #expect(h.requests == 1)
    }

    enum Cancellation: CaseIterable {
        case interaction, navigation, blocked, focus, removal, anotherSurface
    }

    @Test(arguments: Cancellation.allCases)
    func cancelledInvitationsWaitForAnotherWorkspaceReturn(_ reason: Cancellation) throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 300)
        h.update(.reviewPage("settings"))
        switch reason {
        case .interaction: h.controller.recordInteraction(surfaceID: h.surfaceID)
        case .navigation: h.update(.reviewPage("settings.app"))
        case .blocked: h.update(.reviewPage("settings"), blocked: true)
        case .focus: h.update(.reviewPage("settings"), active: false)
        case .removal: h.controller.removeSurface(h.surfaceID)
        case .anotherSurface:
            h.controller.update(
                surfaceID: UUID(), context: .init(location: .reviewPage("settings"), isActive: true)
            )
        }
        h.advance(10)
        h.update(.reviewPage("settings"))
        h.request()
        #expect(h.requests == 0)
        h.work(for: 0)
        h.finish()
        #expect(h.requests == 1)
    }

    @Test
    func blockedReturnAndEditorExitDoNotArmRequests() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 300)
        h.update(.reviewPage("settings"), blocked: true)
        h.advance(10)
        h.update(.reviewPage("settings"))
        h.request()
        #expect(h.requests == 0)
        h.work(for: 0)
        h.update(.other)
        h.advance(10)
        h.update(.reviewPage("settings"))
        h.request()
        #expect(h.requests == 0)
    }

    @Test
    func multipleSurfacesShareTimeAndCannotIssueDuplicateRequests() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 150)
        let secondSurface = UUID()
        h.controller.update(
            surfaceID: secondSurface, context: .init(location: .workspace(UUID()), isActive: true)
        )
        h.advance(149)
        h.controller.update(
            surfaceID: secondSurface, context: .init(location: .reviewPage("settings"), isActive: true)
        )
        h.advance(3)
        h.controller.requestIfReady(surfaceID: secondSurface) { h.requests += 1 }
        #expect(h.requests == 0)
        h.work(for: 1)
        h.finish()
        #expect(h.requests == 1)
        h.controller.update(
            surfaceID: secondSurface, context: .init(location: .workspace(UUID()), isActive: true)
        )
        h.controller.update(
            surfaceID: secondSurface, context: .init(location: .reviewPage("settings"), isActive: true)
        )
        h.advance(3)
        h.controller.requestIfReady(surfaceID: secondSurface) { h.requests += 1 }
        #expect(h.requests == 1)
    }

    @Test
    func persistedVersionBudgetAndCooldownSurviveRelaunchWithoutRestoringWorkspaceTime() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 300)
        h.finish()
        let firstAttempt = h.date
        h.controller = h.makeController(version: "1.1")
        h.date = firstAttempt.addingTimeInterval(120 * 86_400 - 1)
        h.work(for: 0)
        h.update(.reviewPage("settings"))
        h.advance(3, wallTime: false)
        h.request()
        #expect(h.requests == 1)
        h.work(for: 300, wallTime: false)
        h.update(.reviewPage("settings"))
        h.advance(3, wallTime: false)
        h.request()
        #expect(h.requests == 1)
        h.date = firstAttempt.addingTimeInterval(120 * 86_400)
        h.work(for: 0)
        h.finish()
        #expect(h.requests == 2)
        h.controller = h.makeController(version: "1.0")
        h.advance(121 * 86_400)
        h.work(for: 300)
        h.finish()
        #expect(h.requests == 2)
    }

    @Test
    func manualLinkCancelsPendingRequestAndRestartsCooldownWithoutClaimingARating() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 300)
        h.update(.reviewPage("settings.app"))
        h.controller.recordManualReview()
        h.advance(3)
        h.request()
        #expect(h.requests == 0)
        #expect(h.defaults.object(forKey: SettingsKey.reviewRequestedVersions) == nil)
        h.work(for: 0)
        h.finish()
        #expect(h.requests == 0)
        h.advance(120 * 86_400)
        h.work(for: 0)
        h.finish()
        #expect(h.requests == 1)
    }

    @Test
    func wallClockRollbackDoesNotIncreaseWorkspaceTimeOrBypassCooldown() throws {
        let h = try Harness()
        defer { h.clear() }
        h.mature()
        h.work(for: 299)
        h.date = h.date.addingTimeInterval(86_400)
        h.finish()
        #expect(h.requests == 0)
        h.work(for: 1)
        h.finish()
        #expect(h.requests == 1)
        h.controller = h.makeController(version: "1.1")
        h.date = h.firstDate
        h.work(for: 300)
        h.finish()
        #expect(h.requests == 1)
    }

    @Test
    func disabledControllersLeaveUsageUntouched() throws {
        let h = try Harness()
        defer { h.clear() }
        h.controller = AppReviewController(defaults: h.defaults, version: "1.0")
        h.mature()
        h.work(for: 300)
        h.finish()
        #expect(h.requests == 0)
        #expect(h.defaults.object(forKey: SettingsKey.reviewFirstUse) == nil)
        #expect(h.activeDays == 0)
    }

    private final class Harness {
        let suite = "AppReviewControllerTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let firstDate = Date(timeIntervalSince1970: 1_735_689_600)
        var date = Date(timeIntervalSince1970: 1_735_689_600)
        var tick: TimeInterval = 0
        let surfaceID = UUID()
        let workspaceID = UUID()
        var requests = 0
        var controller = AppReviewController()

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            controller = makeController(version: "1.0")
        }

        func makeController(version: String) -> AppReviewController {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return AppReviewController(
                defaults: defaults, version: version, isEnabled: true,
                now: { [unowned self] in self.date },
                uptime: { [unowned self] in self.tick }, calendar: calendar
            )
        }

        var activeDays: Int { defaults.stringArray(forKey: SettingsKey.reviewActiveDays)?.count ?? 0 }

        func clear() { defaults.removePersistentDomain(forName: suite) }

        func advance(_ seconds: TimeInterval, wallTime: Bool = true) {
            tick += seconds
            if wallTime { date = date.addingTimeInterval(seconds) }
        }

        func update(_ location: AppReviewController.Location, active: Bool = true, blocked: Bool = false) {
            controller.update(
                surfaceID: surfaceID,
                context: .init(location: location, isActive: active, isBlocked: blocked)
            )
        }

        func mature() {
            update(.reviewPage("vault.hosts"))
            advance(86_400)
            update(.reviewPage("vault.hosts"))
            advance(6 * 86_400)
            update(.reviewPage("vault.hosts"))
        }

        func work(for seconds: TimeInterval, wallTime: Bool = true) {
            update(.workspace(workspaceID))
            advance(seconds, wallTime: wallTime)
        }

        func finish() {
            update(.reviewPage("settings"))
            advance(3)
            request()
        }

        func request() { controller.requestIfReady(surfaceID: surfaceID) { requests += 1 } }
    }
}
