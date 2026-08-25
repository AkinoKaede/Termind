import Foundation

/// `@AppStorage` keys in one place.
///
/// String literals scattered across views are how a preference silently splits
/// into two preferences that disagree. Everything user-facing that lives in
/// `UserDefaults` rather than SwiftData is named here.
nonisolated enum SettingsKey {
    /// Hide the `user@host` second line in sidebar rows.
    static let compactSidebar = "sidebar.compact"
    /// Show the "Recents" section at all.
    static let showRecents = "sidebar.showRecents"
    /// Terminal palette name, matched against `GhosttyThemeCatalog`.
    static let terminalThemeDark = "terminal.theme.dark"
    static let terminalThemeLight = "terminal.theme.light"
    static let terminalCustomConfigurationDarkEnabled =
        "terminal.customConfiguration.dark.enabled"
    static let terminalCustomConfigurationLightEnabled =
        "terminal.customConfiguration.light.enabled"
    static let terminalCustomConfigurationDark = "terminal.customConfiguration.dark"
    static let terminalCustomConfigurationLight = "terminal.customConfiguration.light"
    static let terminalFontFollowTheme = "terminal.font.followTheme"
    static let defaultTerminalThemeDark = "Termind Dark"
    static let defaultTerminalThemeLight = "Termind Light"
    static let terminalFontSize = "terminal.fontSize"
    /// Enable session-scoped hooks that report remote shell and system context.
    static let shellIntegration = "terminal.shellIntegration"
    static var isShellIntegrationEnabled: Bool {
        UserDefaults.standard.object(forKey: shellIntegration) as? Bool ?? true
    }
    /// Restore the previous window's tabs on launch.
    static let restoreTabs = "window.restoreTabs"
    static let sftpGlobalTransferLimit = "sftp.transfers.globalLimit"
    static let sftpPerHostTransferLimit = "sftp.transfers.perHostLimit"
    static let defaultSFTPGlobalTransferLimit = 3
    static let defaultSFTPPerHostTransferLimit = 2

    /// Let the assistant search the web.
    ///
    /// On by default, which it can only be because the default backend needs no
    /// account: `SearchBackend.default` reads a results page the way a browser
    /// would. A default that required a key would be a switch that did nothing
    /// until the user went and got one, which is the same as off.
    static let webSearchEnabled = "search.enabled"
    static let defaultWebSearchEnabled = true
    static var isWebSearchEnabled: Bool {
        UserDefaults.standard.object(forKey: webSearchEnabled) as? Bool ?? defaultWebSearchEnabled
    }
    /// Let a provider run the search on its own servers where it can.
    ///
    /// On by default, because where it works it beats a snippet API: the
    /// provider reads whole pages and the model simply knows things. Off is the
    /// compatibility position — every model then goes through the backend
    /// below, which behaves identically on every endpoint.
    ///
    /// The switch exists because whether a given endpoint really runs the
    /// search is a *guess*: `ModelProvider.supportsNativeWebSearch(model:)`
    /// infers it from the model id, and a gateway can make that inference wrong
    /// in either direction. This is the escape hatch for when it is.
    static let webSearchBuiltIn = "search.builtIn"
    static let defaultWebSearchBuiltIn = true
    static var isBuiltInWebSearchEnabled: Bool {
        UserDefaults.standard.object(forKey: webSearchBuiltIn) as? Bool
            ?? defaultWebSearchBuiltIn
    }
    /// A `SearchBackend` raw value. Unrecognised falls back to the default.
    static let webSearchBackend = "search.backend"
    /// Blank means the backend's own default, exactly as a model provider's
    /// blank base URL means its kind's default.
    static let webSearchBaseURL = "search.baseURL"
    /// Where the search key is filed in the Keychain. Never the key itself.
    static let webSearchCredentialRef = "search.credentialRef"
}
