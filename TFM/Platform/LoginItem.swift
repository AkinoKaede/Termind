import AppKit
import ServiceManagement

/// Whether launchd opened this process as a login item.
///
/// `SMAppService` reports whether the app is registered, never why the current
/// process started. The launch Apple Event still carries that, but
/// `currentAppleEvent` is only valid while the event is being handled and is
/// gone a moment later, so the answer is latched during
/// `applicationWillFinishLaunching` and read from there on.
@MainActor
enum LoginLaunch {
    private(set) static var wasLaunchedAtLogin = false

    /// Latches a `true` and never clears it, so it can be called from both
    /// `applicationWillFinishLaunching` and `applicationDidFinishLaunching`
    /// without the second, later call erasing what the first one saw.
    static func capture(
        currentEvent: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) {
        wasLaunchedAtLogin = wasLaunchedAtLogin || isLoginItemLaunch(currentEvent)
    }

    /// Kept pure and separate from the latch so a test can build the descriptor
    /// instead of logging out of macOS.
    nonisolated static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }
}

/// The login item, as macOS currently has it.
///
/// Deliberately without a preference mirroring the registration. Someone can
/// remove Termind in System Settings › General › Login Items at any time, and a
/// remembered `true` would then describe a registration that no longer exists.
/// `SMAppService` is the store for *whether* Termind opens at login; only *how*
/// it opens is kept in preferences.
@MainActor
@Observable
final class LoginItemController {
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let showSystemSettings: () -> Void

    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?

    init(
        status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
        showSystemSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        readStatus = status
        self.register = register
        self.unregister = unregister
        self.showSystemSettings = showSystemSettings
        self.status = status()
    }

    /// On as far as this app is concerned. `requiresApproval` counts: the
    /// request is on file and only the user's consent is outstanding, so the
    /// switch keeps showing what they asked for instead of snapping back while
    /// the row below explains what is missing.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    /// macOS has the registration but the user has not allowed it yet. Nothing
    /// opens at login until they do, which is why this is said out loud.
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = readStatus()
        errorMessage = nil
    }

    /// Reports what macOS ended up doing rather than what was asked of it.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        errorMessage = nil
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            errorMessage = Self.message(for: error)
        }
        status = readStatus()
        // Waiting on approval is refused with "Operation not permitted", which
        // says nothing the approval row does not say better.
        if requiresApproval { errorMessage = nil }
    }

    func openSystemSettings() { showSystemSettings() }

    private static func message(for error: any Error) -> String {
        let description = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty
            ? String(localized: "Unable to update the login item.")
            : description
    }
}
