import AgentKit
import Foundation
import TermindApplication

/// `@AppStorage` keys in one place.
///
/// String literals scattered across views are how a preference silently splits
/// into two preferences that disagree. Everything user-facing that lives in
/// `UserDefaults` rather than SwiftData is named here.
nonisolated enum DesktopSettingsKey {
    // Device-local review invitation history; never included in Settings sync.
    static let reviewFirstUse = "app.review.firstUse"
    static let reviewActiveDays = "app.review.activeDays"
    static let reviewLastAttempt = "app.review.lastAttempt"
    static let reviewRequestedVersions = "app.review.requestedVersions"

    static let showMetricsInMenuBar = "metrics.showInMenuBar"
    /// App-wide appearance. `system` inherits changes from macOS.
    static let appAppearance = "app.appearance"

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
    static var isShellIntegrationEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.shellIntegration) as? Bool ?? true
    }
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
    static var isWebSearchEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.webSearchEnabled) as? Bool
            ?? SettingsKey.defaultWebSearchEnabled
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
    static var isBuiltInWebSearchEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.webSearchBuiltIn) as? Bool
            ?? SettingsKey.defaultWebSearchBuiltIn
    }
}
