import AppKit
import Foundation
import ServiceManagement
import Testing

@testable import Termind

@Suite
@MainActor
struct LoginItemTests {
    /// Stands in for `SMAppService.mainApp`, which a test cannot register
    /// against without changing the machine it runs on.
    @MainActor
    private final class LoginItemSystem {
        var status: SMAppService.Status
        /// What the status reads as after a register attempt. macOS can both
        /// throw *and* move the status: a registration the user has not allowed
        /// is refused and lands in `requiresApproval`.
        var statusAfterRegister: SMAppService.Status = .enabled
        var registerError: (any Error)?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        private(set) var systemSettingsCount = 0

        init(status: SMAppService.Status) { self.status = status }

        func makeController() -> LoginItemController {
            LoginItemController(
                status: { self.status },
                register: {
                    self.registerCount += 1
                    self.status = self.statusAfterRegister
                    if let error = self.registerError { throw error }
                },
                unregister: {
                    self.unregisterCount += 1
                    self.status = .notRegistered
                },
                showSystemSettings: { self.systemSettingsCount += 1 }
            )
        }
    }

    private struct RegistrationFailure: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    private static func launchEvent(
        eventID: AEEventID = AEEventID(kAEOpenApplication),
        loginItemFlag: Bool
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if loginItemFlag {
            event.setParam(
                NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
                forKeyword: keyAEPropData
            )
        }
        return event
    }

    @Test
    func loginLaunchIsDetectedOnlyForTheLoginItemOpenEvent() {
        #expect(LoginLaunch.isLoginItemLaunch(Self.launchEvent(loginItemFlag: true)))
        #expect(!LoginLaunch.isLoginItemLaunch(Self.launchEvent(loginItemFlag: false)))
        #expect(
            !LoginLaunch.isLoginItemLaunch(
                Self.launchEvent(eventID: AEEventID(kAEReopenApplication), loginItemFlag: true)
            )
        )
        #expect(!LoginLaunch.isLoginItemLaunch(nil))
    }

    @Test
    func enablingRegistersOnceAndReportsTheSystemStatus() {
        let system = LoginItemSystem(status: .notRegistered)
        let controller = system.makeController()
        #expect(!controller.isEnabled)

        controller.setEnabled(true)

        #expect(system.registerCount == 1)
        #expect(controller.isEnabled)
        #expect(!controller.requiresApproval)
        #expect(controller.errorMessage == nil)

        // Setting what is already set asks macOS for nothing.
        controller.setEnabled(true)
        #expect(system.registerCount == 1)
    }

    @Test
    func approvalPendingKeepsTheSwitchOnAndAsksForSystemSettings() {
        let system = LoginItemSystem(status: .notRegistered)
        system.statusAfterRegister = .requiresApproval
        system.registerError = RegistrationFailure()
        let controller = system.makeController()

        controller.setEnabled(true)

        #expect(system.registerCount == 1)
        #expect(controller.requiresApproval)
        // Snapping back to off would deny the choice the user just made; the
        // approval row is what explains why nothing opens yet.
        #expect(controller.isEnabled)
        // "Operation not permitted" adds nothing to that row.
        #expect(controller.errorMessage == nil)

        controller.openSystemSettings()
        #expect(system.systemSettingsCount == 1)
    }

    @Test
    func registrationFailureSurfacesTheErrorAndKeepsTheSystemStatusAuthoritative() {
        let system = LoginItemSystem(status: .notFound)
        system.statusAfterRegister = .notFound
        system.registerError = RegistrationFailure()
        let controller = system.makeController()

        controller.setEnabled(true)

        #expect(controller.errorMessage == "Operation not permitted")
        #expect(!controller.isEnabled)
        #expect(!controller.requiresApproval)
    }

    @Test
    func disablingUnregisters() {
        let system = LoginItemSystem(status: .enabled)
        let controller = system.makeController()
        #expect(controller.isEnabled)

        controller.setEnabled(false)

        #expect(system.unregisterCount == 1)
        #expect(!controller.isEnabled)
    }

    @Test
    func refreshingPicksUpARemovalMadeOutsideTheApp() {
        let system = LoginItemSystem(status: .enabled)
        let controller = system.makeController()
        #expect(controller.isEnabled)

        system.status = .notRegistered
        #expect(controller.isEnabled)

        controller.refresh()
        #expect(!controller.isEnabled)
    }

    @Test
    func openingHiddenIsOffUntilTheUserAsksForIt() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: SettingsKey.openAtLoginQuietly)
        defer { defaults.set(original, forKey: SettingsKey.openAtLoginQuietly) }

        defaults.removeObject(forKey: SettingsKey.openAtLoginQuietly)
        #expect(!SettingsKey.opensAtLoginQuietly)

        defaults.set(true, forKey: SettingsKey.openAtLoginQuietly)
        #expect(SettingsKey.opensAtLoginQuietly)
    }
}
