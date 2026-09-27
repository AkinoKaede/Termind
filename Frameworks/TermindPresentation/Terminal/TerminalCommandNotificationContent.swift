import SwiftUI
import TermindApplication

public enum CommandNotificationContent {
    public static func body(_ completion: TerminalCommandCompletion) -> String {
        let duration = Duration.seconds(completion.duration).formatted(.units(allowed: [.hours, .minutes, .seconds]))
        let result: LocalizedStringResource
        switch completion.exitCode {
        case 0: result = AppStrings.CommandNotifications.succeeded(duration)
        case .some(let code): result = AppStrings.CommandNotifications.failed(code, duration)
        case nil: result = AppStrings.CommandNotifications.finished(duration)
        }
        return (completion.commandPreview ?? String(localized: AppStrings.CommandNotifications.completed))
            + "\n" + String(localized: result)
    }
}
