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
    public var copyOnSelect = false
    public var pasteOnRightClick = false
    public init(
        fontSize: Double = 12.0, fontFollowTheme: Bool = true, darkTheme: String = "Termind Dark",
        lightTheme: String = "Termind Light", darkCustomEnabled: Bool = false, lightCustomEnabled: Bool = false,
        darkCustomConfiguration: String = "", lightCustomConfiguration: String = "", shellIntegration: Bool = true,
        remoteWindowTitleInMenuBar: Bool = true, copyOnSelect: Bool = false, pasteOnRightClick: Bool = false
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
        self.copyOnSelect = copyOnSelect
        self.pasteOnRightClick = pasteOnRightClick
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize, fontFollowTheme, darkTheme, lightTheme, darkCustomEnabled, lightCustomEnabled
        case darkCustomConfiguration, lightCustomConfiguration, shellIntegration, remoteWindowTitleInMenuBar
        case copyOnSelect, pasteOnRightClick
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try values.decode(Double.self, forKey: .fontSize)
        fontFollowTheme = try values.decode(Bool.self, forKey: .fontFollowTheme)
        darkTheme = try values.decode(String.self, forKey: .darkTheme)
        lightTheme = try values.decode(String.self, forKey: .lightTheme)
        darkCustomEnabled = try values.decode(Bool.self, forKey: .darkCustomEnabled)
        lightCustomEnabled = try values.decode(Bool.self, forKey: .lightCustomEnabled)
        darkCustomConfiguration = try values.decode(String.self, forKey: .darkCustomConfiguration)
        lightCustomConfiguration = try values.decode(String.self, forKey: .lightCustomConfiguration)
        shellIntegration = try values.decode(Bool.self, forKey: .shellIntegration)
        remoteWindowTitleInMenuBar = try values.decode(Bool.self, forKey: .remoteWindowTitleInMenuBar)
        // Existing local blobs and Settings sync records predate the mouse preferences.
        copyOnSelect = try values.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? false
        pasteOnRightClick = try values.decodeIfPresent(Bool.self, forKey: .pasteOnRightClick) ?? false
    }

}
