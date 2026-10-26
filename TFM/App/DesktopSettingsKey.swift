// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// `@AppStorage` keys in one place.
///
/// String literals scattered across views are how a preference silently splits
/// into two preferences that disagree. Everything user-facing that lives in
/// `UserDefaults` rather than SwiftData is named here.
nonisolated enum DesktopSettingsKey {
    static let showMetricsInMenuBar = "metrics.showInMenuBar"
    /// Visibility is local to this Mac, independent of the capsule's expanded state.
    static let showStatusBar = "statusBar.visible"
    static let showTerminalInputArea = "terminal.inputArea.visible"
    static let terminalInputAreaDefaultHeight = "terminal.inputArea.defaultHeight"
    /// App-wide appearance. `system` inherits changes from macOS.
    static let appAppearance = "app.appearance"
    /// Last ordinary main-window content size, local to this Mac.
    static let mainWindowSize = "window.main.contentSize"
    static let mainWindowSidebarWidth = "window.main.sidebarWidth"
    static let mainWindowShowsSidebar = "window.main.showsSidebar"

    // Built-in MCP listener preferences are device-local and never enter Settings sync.
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
    static let onboardingQuickOpenCompleted = "onboarding.quickOpen.completed"
    static let onboardingStatusBarPathCompleted = "onboarding.statusBarPath.completed"
    static let onboardingCommandGeneratorCompleted = "onboarding.commandGenerator.completed"
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
}
