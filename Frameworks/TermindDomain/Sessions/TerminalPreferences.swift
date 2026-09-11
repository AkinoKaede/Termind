import Foundation

public nonisolated struct TerminalPreferences: Codable, Hashable, Sendable {
    public var fontSize = 12.0
    public var fontFollowTheme = true
    public var darkTheme = "Termind Dark"
    public var lightTheme = "Termind Light"
    public var darkCustomEnabled = false
    public var lightCustomEnabled = false
    public var darkCustomConfiguration = ""
    public var lightCustomConfiguration = ""
    public var shellIntegration = true
    public var remoteWindowTitleInMenuBar = true
    public init(
        fontSize: Double = 12.0, fontFollowTheme: Bool = true, darkTheme: String = "Termind Dark",
        lightTheme: String = "Termind Light", darkCustomEnabled: Bool = false, lightCustomEnabled: Bool = false,
        darkCustomConfiguration: String = "", lightCustomConfiguration: String = "", shellIntegration: Bool = true,
        remoteWindowTitleInMenuBar: Bool = true
    ) {
        self.fontSize = fontSize
        self.fontFollowTheme = fontFollowTheme
        self.darkTheme = darkTheme
        self.lightTheme = lightTheme
        self.darkCustomEnabled = darkCustomEnabled
        self.lightCustomEnabled = lightCustomEnabled
        self.darkCustomConfiguration = darkCustomConfiguration
        self.lightCustomConfiguration = lightCustomConfiguration
        self.shellIntegration = shellIntegration
        self.remoteWindowTitleInMenuBar = remoteWindowTitleInMenuBar
    }

}
