import Foundation

/// `@AppStorage` keys in one place.
///
/// String literals scattered across views are how a preference silently splits
/// into two preferences that disagree. Everything user-facing that lives in
/// `UserDefaults` rather than SwiftData is named here.
nonisolated enum SettingsKey {
    /// App language selection. `system` means normal Bundle negotiation.
    static let appLanguage = "app.language"
    static let vaultSyncEnabled = "vault.sync.enabled"
    /// The CloudKit environment owning the persisted sync engine state and
    /// record system fields. Debug and TestFlight share the app container, but
    /// CloudKit development change tags are invalid in production (and vice
    /// versa), so an environment switch must rebind the local journal.
    static let vaultSyncEnvironment = "vault.sync.environment"
    static let defaultVaultSyncEnabled = true
    static let mcpServerEnabled = "mcpServer.enabled"
    static let mcpServerPort = "mcpServer.port"
    static let mcpServerDisabledTools = "mcpServer.disabledTools"
    static let defaultMCPServerEnabled = false
    static let defaultMCPServerPort = 7_391

    /// Show the "Recents" section at all.
    static let showRecents = "sidebar.showRecents"
    static let vaultSectionExpanded = "sidebar.section.vault.expanded"
    static let workspaceSectionExpanded = "sidebar.section.workspace.expanded"
    static let chatsSectionExpanded = "sidebar.section.chats.expanded"
    static let pinnedChatsSectionExpanded = "sidebar.section.pinnedChats.expanded"
    static let recentsSectionExpanded = "sidebar.section.recents.expanded"
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
    /// Restore the previous window's Workspaces on launch. Keep the persisted
    /// key stable so this UI rename does not discard the user's preference.
    static let restoreWorkspaces = "window.restoreTabs"
    /// The last approval posture selected in the Assistant composer.
    static let agentPermissionMode = "assistant.permissionMode"
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
    /// Summarize older turns automatically as a conversation approaches the
    /// model's context window.
    ///
    /// On by default, and it can be because there is nothing to configure for it
    /// to work: it uses the Chat model the conversation is already using, on the
    /// key already in play. Off is for someone who would rather be told the
    /// window is full and decide themselves — `/compact` still works.
    static let autoCompactEnabled = "assistant.autoCompact"
    static let defaultAutoCompactEnabled = true
    static var isAutoCompactEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCompactEnabled) as? Bool
            ?? defaultAutoCompactEnabled
    }

    /// Headroom held back for the reply when deciding whether to compact.
    /// Pi's default.
    static let compactionReserveTokens = "assistant.compaction.reserveTokens"
    static var compactionReserve: Int {
        let stored = UserDefaults.standard.integer(forKey: compactionReserveTokens)
        return stored > 0 ? stored : AgentCompaction.defaultReserveTokens
    }

    /// Recent history never summarized. Pi's default.
    static let compactionKeepRecentTokens = "assistant.compaction.keepRecentTokens"
    static var compactionKeepRecent: Int {
        let stored = UserDefaults.standard.integer(forKey: compactionKeepRecentTokens)
        return stored > 0 ? stored : AgentCompaction.defaultKeepRecentTokens
    }
}
