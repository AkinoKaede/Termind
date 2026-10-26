// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct TerminalPreferences: Codable, Hashable, Sendable {
    public var darkTheme = "Termind Dark"
    public var lightTheme = "Termind Light"
    public var darkCustomEnabled = false
    public var lightCustomEnabled = false
    public var darkCustomConfiguration = ""
    public var lightCustomConfiguration = ""
    public var shellIntegration = true
    public init(
        darkTheme: String = "Termind Dark",
        lightTheme: String = "Termind Light", darkCustomEnabled: Bool = false, lightCustomEnabled: Bool = false,
        darkCustomConfiguration: String = "", lightCustomConfiguration: String = "", shellIntegration: Bool = true
    ) {
        self.darkTheme = darkTheme
        self.lightTheme = lightTheme
        self.darkCustomEnabled = darkCustomEnabled
        self.lightCustomEnabled = lightCustomEnabled
        self.darkCustomConfiguration = darkCustomConfiguration
        self.lightCustomConfiguration = lightCustomConfiguration
        self.shellIntegration = shellIntegration
    }

    private enum CodingKeys: String, CodingKey {
        case darkTheme, lightTheme, darkCustomEnabled, lightCustomEnabled
        case darkCustomConfiguration, lightCustomConfiguration, shellIntegration
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        darkTheme = try values.decode(String.self, forKey: .darkTheme)
        lightTheme = try values.decode(String.self, forKey: .lightTheme)
        darkCustomEnabled = try values.decode(Bool.self, forKey: .darkCustomEnabled)
        lightCustomEnabled = try values.decode(Bool.self, forKey: .lightCustomEnabled)
        darkCustomConfiguration = try values.decode(String.self, forKey: .darkCustomConfiguration)
        lightCustomConfiguration = try values.decode(String.self, forKey: .lightCustomConfiguration)
        shellIntegration = try values.decode(Bool.self, forKey: .shellIntegration)
    }

}
