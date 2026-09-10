import Foundation

nonisolated struct TerminalPreferences: Codable, Hashable, Sendable {
    var fontSize = 12.0
    var fontFollowTheme = true
    var darkTheme = "Termind Dark"
    var lightTheme = "Termind Light"
    var darkCustomEnabled = false
    var lightCustomEnabled = false
    var darkCustomConfiguration = ""
    var lightCustomConfiguration = ""
    var shellIntegration = true
    var remoteWindowTitleInMenuBar = true
}
