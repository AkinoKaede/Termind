// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum SettingsKey {
    // Device-local privacy consent; absence means the user has not chosen yet.
    // Preserve the original storage key so a terminology change does not reset consent.
    public static let diagnosisConsent = "diagnostics.crashReportingConsent"

    // Debug visibility and logging are device-local and never included in Settings sync.
    public static let debugSectionEnabled = "debug.section.enabled"
    public static let loggingSavingEnabled = "debug.logging.savingEnabled"
    public static let loggingLevel = "debug.logging.level"

    // Device-local review invitation state; never included in Settings sync.
    public static let reviewFirstUse = "app.review.firstUse"
    public static let reviewInvitationResponse = "app.review.invitationResponse"

    public static let appLanguage = "app.language"
    public static let defaultICloudSyncEnabled = true
    public static let defaultMetricsSyncEnabled = true
    public static let defaultSettingsSyncEnabled = true
    public static let defaultTerminalThemeDark = "Termind Dark"
    public static let defaultTerminalThemeLight = "Termind Light"
    public static let defaultVaultSyncEnabled = true
    public static let defaultHistorySyncEnabled = true
    public static let historySyncEnabled = "history.sync.enabled"
    public static let deviceSyncEnvironment = "device.sync.environment"
    public static let historySyncEnvironment = "history.sync.environment"
    public static let defaultWebSearchBuiltIn = true
    public static let defaultWebSearchEnabled = true
    public static let iCloudSyncEnabled = "icloud.sync.enabled"
    public static let metricsSyncEnabled = "metrics.sync.enabled"
    public static let metricsSyncEnvironment = "metrics.sync.environment"
    public static let settingsSyncEnabled = "settings.sync.enabled"
    public static let settingsSyncEnvironment = "settings.sync.environment"
    public static let shellIntegration = "terminal.shellIntegration"
    public static let sshMaxSessions = "ssh.maxSessions"
    public static let defaultSSHMaxSessions = SSHPreferences.defaultMaxSessions
    public static let sshMaxSessionsRange = SSHPreferences.maxSessionsRange
    public static let sftpConcurrencyStrategy = "sftp.transfers.strategy"
    public static let sftpGlobalTransferLimit = "sftp.transfers.globalLimit"
    public static let sftpPerHostTransferLimit = "sftp.transfers.perHostLimit"
    public static let defaultSFTPGlobalTransferLimit = SFTPPreferences.defaultGlobalLimit
    public static let defaultSFTPPerHostTransferLimit = SFTPPreferences.defaultPerHostLimit
    public static let sftpGlobalTransferLimitRange = SFTPPreferences.globalLimitRange
    public static let sftpPerHostTransferLimitRange = SFTPPreferences.perHostLimitRange
    public static let terminalCustomConfigurationDark = "terminal.customConfiguration.dark"
    public static let terminalCustomConfigurationDarkEnabled = "terminal.customConfiguration.dark.enabled"
    public static let terminalCustomConfigurationLight = "terminal.customConfiguration.light"
    public static let terminalCustomConfigurationLightEnabled = "terminal.customConfiguration.light.enabled"
    // Typography is device-local and never enters Settings sync.
    public static let terminalFontFamily = "terminal.fontFamily"
    public static let terminalFontFollowTheme = "terminal.font.followTheme"
    public static let terminalFontSize = "terminal.fontSize"
    public static let terminalCopyOnSelect = "terminal.copyOnSelect"
    public static let terminalPasteOnRightClick = "terminal.pasteOnRightClick"
    public static let terminalBellSound = "terminal.bellSound"
    public static let terminalBellVibration = "terminal.bellVibration"
    public static let terminalKeepScreenAwake = "terminal.keepScreenAwake"
    public static let terminalThemeDark = "terminal.theme.dark"
    public static let terminalThemeLight = "terminal.theme.light"
    // Migration-only key: configuration now follows the master switch.
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

public nonisolated enum NewVaultCredentialStorage {
    public static func keyStorage(
        defaults: UserDefaults = .standard,
        canUseVaultSync: Bool
    ) -> KeyStorage {
        vaultSyncIsAvailable(defaults: defaults, canUseVaultSync: canUseVaultSync)
            ? .iCloud : .thisDevice
    }

    public static func passwordStorage(
        defaults: UserDefaults = .standard,
        canUseVaultSync: Bool
    ) -> PasswordStorage {
        vaultSyncIsAvailable(defaults: defaults, canUseVaultSync: canUseVaultSync)
            ? .iCloud : .thisDevice
    }

    private static func vaultSyncIsAvailable(
        defaults: UserDefaults,
        canUseVaultSync: Bool
    ) -> Bool {
        let iCloudEnabled =
            defaults.object(forKey: SettingsKey.iCloudSyncEnabled) as? Bool
            ?? SettingsKey.defaultICloudSyncEnabled
        return iCloudEnabled && canUseVaultSync
    }
}
