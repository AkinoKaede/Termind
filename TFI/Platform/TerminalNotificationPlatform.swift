import UIKit

@MainActor
enum TerminalNotificationPlatform {
    static var soundURL: URL? { Bundle.main.url(forResource: "bell", withExtension: "wav") }

    static func ringBell() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let url = soundURL
        else { return }
        MobileSystemSoundPlayer.live.play(url: url)
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
