import Foundation

extension AppStrings {
    public nonisolated enum CommandNotifications {
        public static var when: LocalizedStringResource { "Notify When" }
        public static var never: LocalizedStringResource { "Never" }
        public static var always: LocalizedStringResource { "Always" }
        public static var minimumDuration: LocalizedStringResource { "Minimum Duration (s)" }
        public static var openSettings: LocalizedStringResource { "Open Notification Settings" }
        public static var denied: LocalizedStringResource { "Notifications are disabled in system settings." }
        public static var unread: LocalizedStringResource { "Unread command completion" }
        public static var explanation: LocalizedStringResource {
            "Requires shell integration or OSC 133."
        }
        public static func succeeded(_ command: String?, _ duration: String) -> LocalizedStringResource {
            if let command { return "“\(command)” completed successfully in \(duration)." }
            return "Command completed successfully in \(duration)."
        }
        public static func failed(_ command: String?, _ code: Int, _ duration: String) -> LocalizedStringResource {
            if let command { return "“\(command)” failed with exit code \(code) after \(duration)." }
            return "Command failed with exit code \(code) after \(duration)."
        }
        public static func finished(_ command: String?, _ duration: String) -> LocalizedStringResource {
            if let command { return "“\(command)” finished after \(duration)." }
            return "Command finished after \(duration)."
        }
    }
}
