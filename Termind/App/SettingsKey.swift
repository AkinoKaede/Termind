import AgentKit
import Foundation

/// `@AppStorage` keys in one place.
///
/// String literals scattered across views are how a preference silently splits
/// into two preferences that disagree. Everything user-facing that lives in
/// `UserDefaults` rather than SwiftData is named here.
nonisolated enum SettingsKey {
    /// App language selection. `system` means normal Bundle negotiation.
    static let showMetricsInMenuBar = "metrics.showInMenuBar"
    static let appLanguage = "app.language"
    /// App-wide appearance. `system` inherits changes from macOS.
    static let appAppearance = "app.appearance"
    static let iCloudSyncEnabled = "icloud.sync.enabled"
    static let defaultICloudSyncEnabled = true
    static let settingsSyncEnabled = "settings.sync.enabled"
    static let settingsSyncEnvironment = "settings.sync.environment"
    static let defaultSettingsSyncEnabled = false
    static let vaultSyncEnabled = "vault.sync.enabled"
    /// The CloudKit environment owning the persisted sync engine state and
    /// record system fields. Debug and TestFlight share the app container, but
    /// CloudKit development change tags are invalid in production (and vice
    /// versa), so an environment switch must rebind the local journal.
    static let vaultSyncEnvironment = "vault.sync.environment"
    static let defaultVaultSyncEnabled = true
    static func migrateSyncPreferences(in defaults: UserDefaults = .standard) {
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

    static let mcpServerEnabled = "mcpServer.enabled"
    static let mcpServerPort = "mcpServer.port"
    static let mcpServerDisabledTools = "mcpServer.disabledTools"
    static let defaultMCPServerEnabled = false
    static let defaultMCPServerPort = 7_391

    static let vaultSectionExpanded = "sidebar.section.vault.expanded"
    static let workspaceSectionExpanded = "sidebar.section.workspace.expanded"
    static let chatsSectionExpanded = "sidebar.section.chats.expanded"
    static let pinnedChatsSectionExpanded = "sidebar.section.pinnedChats.expanded"
    static let snippetsSidebarCollapsedSections = "sidebar.snippets.collapsedSections"
    /// Whether the floating status capsule shows its session details or is
    /// shrunk to its status dot. App-wide: it is a standing preference about
    /// how much of the pane you want covered, not a property of one session.
    static let statusBarExpanded = "statusBar.expanded"
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
    /// Mirror the focused SSH terminal's OSC 0/2 title in the macOS menu bar.
    static let remoteWindowTitleInMenuBar = "terminal.remoteWindowTitleInMenuBar"
    static let defaultRemoteWindowTitleInMenuBarEnabled = true
    static let onboardingQuickOpenCompleted = "onboarding.quickOpen.completed"
    static let onboardingStatusBarPathCompleted = "onboarding.statusBarPath.completed"
    static let onboardingCommandGeneratorCompleted = "onboarding.commandGenerator.completed"
    /// Restore the previous window's Workspaces on launch. Keep the persisted
    /// key stable so this UI rename does not discard the user's preference.
    static let restoreWorkspaces = "window.restoreTabs"
    /// Keep Termind behind whatever the user is doing when macOS opens it at
    /// login. Only the launch is quiet; the window is built as usual.
    ///
    /// Off by default: an app that opens where it cannot be seen is a surprise
    /// worth asking for rather than one to hand out.
    ///
    /// Whether Termind opens at login at all is not here. That registration
    /// belongs to `SMAppService`, which the user can undo in System Settings
    /// without telling us — see `LoginItemController`.
    static let openAtLoginQuietly = "startup.openAtLogin.quietly"
    static let defaultOpenAtLoginQuietly = false
    /// Read from the app delegate during launch, where there is no view to hold
    /// an `@AppStorage` binding.
    static var opensAtLoginQuietly: Bool {
        UserDefaults.standard.object(forKey: openAtLoginQuietly) as? Bool
            ?? defaultOpenAtLoginQuietly
    }
    /// The last approval posture selected in the Assistant composer.
    static let agentPermissionMode = "assistant.permissionMode"
    /// How far through `AgentSkillLibrary` the starter skills have been copied
    /// into the user's library. A mark rather than a flag, so a later release
    /// can add one without resurrecting the ones they deleted.
    static let seededSkillGeneration = "assistant.skills.seededGeneration"
    static let sftpGlobalTransferLimit = "sftp.transfers.globalLimit"
    static let sftpPerHostTransferLimit = "sftp.transfers.perHostLimit"
    static let defaultSFTPGlobalTransferLimit = 3
    static let defaultSFTPPerHostTransferLimit = 2

    /// Let the assistant search the web.
    ///
    /// On by default because ScrubberKit searches from this Mac without an
    /// account or API key.
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
}
