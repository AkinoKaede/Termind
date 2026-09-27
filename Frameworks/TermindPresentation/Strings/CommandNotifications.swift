import Foundation

extension AppStrings {
    public nonisolated enum CommandNotifications {
        public static var title: LocalizedStringResource { "Command Completion" }
        public static var when: LocalizedStringResource { "Notify When" }
        public static var never: LocalizedStringResource { "Never" }
        public static var unfocused: LocalizedStringResource { "Workspace Is Unfocused" }
        public static var always: LocalizedStringResource { "Always" }
        public static var system: LocalizedStringResource { "System Notification" }
        public static var bell: LocalizedStringResource { "Terminal Bell" }
        public static var seconds: LocalizedStringResource { "Minimum Duration (seconds)" }
        public static var openSettings: LocalizedStringResource { "Open Notification Settings" }
        public static var denied: LocalizedStringResource { "Notifications are disabled in system settings." }
        public static var unread: LocalizedStringResource { "Unread command completion" }
        public static var explanation: LocalizedStringResource {
            "Requires shell integration or OSC 133. Workspace dots also mark shorter commands."
        }
        public static var mobileExplanation: LocalizedStringResource {
            "Notifications can be delayed while iOS suspends Termind."
        }
        public static var completed: LocalizedStringResource { "Command completed" }
        public static func succeeded(_ duration: String) -> LocalizedStringResource {
            "Succeeded · \(duration)"
        }
        public static func failed(_ code: Int, _ duration: String) -> LocalizedStringResource {
            "Exit code \(code) · \(duration)"
        }
        public static func finished(_ duration: String) -> LocalizedStringResource {
            "Completed · \(duration)"
        }
    }
}
