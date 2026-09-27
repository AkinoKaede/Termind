import SwiftUI
import TermindApplication

public enum CommandNotificationContent {
    public static func body(_ completion: TerminalCommandCompletion) -> String {
        let duration = Duration.seconds(completion.duration).formatted(.units(allowed: [.hours, .minutes, .seconds]))
        let command = completion.commandPreview
        let result: LocalizedStringResource
        switch completion.exitCode {
        case 0: result = AppStrings.CommandNotifications.succeeded(command, duration)
        case .some(let code): result = AppStrings.CommandNotifications.failed(command, code, duration)
        case nil: result = AppStrings.CommandNotifications.finished(command, duration)
        }
        return String(localized: result)
    }
}
