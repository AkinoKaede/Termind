import AudioToolbox
import UIKit

@MainActor
enum TerminalNotificationPlatform {
    static func ringBell() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let url = Bundle.main.url(forResource: "command-finished", withExtension: "wav")
        else { return }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError else { return }
        let identifier = sound
        AudioServicesPlaySystemSoundWithCompletion(identifier) { AudioServicesDisposeSystemSoundID(identifier) }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
