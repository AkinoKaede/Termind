import AppKit

@MainActor
enum TerminalNotificationPlatform {
    static func ringBell() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSSound.beep()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
