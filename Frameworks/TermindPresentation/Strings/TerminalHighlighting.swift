import Foundation

extension AppStrings {
    public nonisolated enum TerminalHighlighting {
        public static var title: LocalizedStringResource { "Keyword Highlighting" }
        public static var addRule: LocalizedStringResource { "Add Highlight Rule" }
        public static var editRule: LocalizedStringResource { "Edit Highlight Rule" }
        public static var pattern: LocalizedStringResource { "Match Pattern" }
        public static var mode: LocalizedStringResource { "Match Mode" }
        public static var text: LocalizedStringResource { "Plain Text" }
        public static var regex: LocalizedStringResource { "Regular Expression" }
        public static var caseSensitive: LocalizedStringResource { "Case Sensitive" }
        public static var explanation: LocalizedStringResource { "Earlier rules take priority." }
        public static var invalidPattern: LocalizedStringResource { "The match pattern is invalid." }
        public static var limits: LocalizedStringResource { "Use a name up to 256 bytes and a pattern up to 16 KB." }
        public static var ruleLimit: LocalizedStringResource { "You can add up to 58 custom highlight rules." }
        public static var foreground: LocalizedStringResource { "Foreground" }
        public static var background: LocalizedStringResource { "Background" }
        public static var moveUp: LocalizedStringResource { "Move Rule Up" }
        public static var moveDown: LocalizedStringResource { "Move Rule Down" }
        public static var error: LocalizedStringResource { "Error" }
        public static var warning: LocalizedStringResource { "Warning" }
        public static var ok: LocalizedStringResource { "OK" }
        public static var info: LocalizedStringResource { "Info" }
        public static var debug: LocalizedStringResource { "Debug" }
        public static var addresses: LocalizedStringResource { "IP address & MAC" }
    }
}
