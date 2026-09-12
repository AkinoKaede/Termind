import Foundation

public nonisolated enum SettingsKey {
    public static let appLanguage = "app.language"
    public static let defaultICloudSyncEnabled = true
    public static let defaultMetricsSyncEnabled = true
    public static let defaultSettingsSyncEnabled = true
    public static let defaultTerminalThemeDark = "Termind Dark"
    public static let defaultTerminalThemeLight = "Termind Light"
    public static let defaultVaultSyncEnabled = true
    public static let defaultWebSearchBuiltIn = true
    public static let defaultWebSearchEnabled = true
    public static let iCloudSyncEnabled = "icloud.sync.enabled"
    public static let metricsSyncEnabled = "metrics.sync.enabled"
    public static let metricsSyncEnvironment = "metrics.sync.environment"
    /// Device-local forwarding intent. It is deliberately excluded from Settings and Vault sync.
    public static let portForwardingEnabledRuleIDs = "portForwarding.enabledRuleIDs"
    public static let remoteWindowTitleInMenuBar = "terminal.remoteWindowTitleInMenuBar"
    public static let seededSkillGeneration = "assistant.skills.seededGeneration"
    public static let settingsSyncEnabled = "settings.sync.enabled"
    public static let settingsSyncEnvironment = "settings.sync.environment"
    public static let shellIntegration = "terminal.shellIntegration"
    public static let sftpGlobalTransferLimit = "sftp.transfers.globalLimit"
    public static let sftpPerHostTransferLimit = "sftp.transfers.perHostLimit"
    public static let defaultSFTPGlobalTransferLimit = 3
    public static let defaultSFTPPerHostTransferLimit = 2
    public static let sftpTransferLimitRange = 1...8
    public static let terminalCustomConfigurationDark = "terminal.customConfiguration.dark"
    public static let terminalCustomConfigurationDarkEnabled = "terminal.customConfiguration.dark.enabled"
    public static let terminalCustomConfigurationLight = "terminal.customConfiguration.light"
    public static let terminalCustomConfigurationLightEnabled = "terminal.customConfiguration.light.enabled"
    public static let terminalFontFollowTheme = "terminal.font.followTheme"
    public static let terminalFontSize = "terminal.fontSize"
    public static let terminalThemeDark = "terminal.theme.dark"
    public static let terminalThemeLight = "terminal.theme.light"
    public static let vaultSyncEnabled = "vault.sync.enabled"
    public static let vaultSyncEnvironment = "vault.sync.environment"
    public static let webSearchBuiltIn = "search.builtIn"
    public static let webSearchEnabled = "search.enabled"
    public static func migrateSyncPreferences(in defaults: UserDefaults = .standard) {
        if defaults.object(forKey: settingsSyncEnabled) == nil,
            let legacy = defaults.object(forKey: "ai.sync.enabled") as? Bool
        {
            defaults.set(legacy, forKey: settingsSyncEnabled)
        }
        guard defaults.object(forKey: iCloudSyncEnabled) == nil else { return }
        let vault = defaults.object(forKey: vaultSyncEnabled) as? Bool ?? defaultVaultSyncEnabled
        let ai = defaults.object(forKey: settingsSyncEnabled) as? Bool ?? defaultSettingsSyncEnabled
        defaults.set(vault || ai, forKey: iCloudSyncEnabled)
        if !vault && !ai { defaults.set(true, forKey: vaultSyncEnabled) }
    }
}
