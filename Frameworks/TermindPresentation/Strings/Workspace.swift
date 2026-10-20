// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum Workspace {
        public static func count(_ count: Int) -> LocalizedStringResource {
            switch count {
            case 1: "One workspace"
            case 2: "Two workspaces"
            default: "\(count) workspaces"
            }
        }

        public static var advisoryTelnetPassword: LocalizedStringResource {
            "This link includes an advisory Telnet password. It will be used once and will not be saved."
        }

        public static var broadcastInput: LocalizedStringResource {
            "Broadcast input"
        }

        public static var broadcastInputToEverySshSessionInThisWorkspaceB: LocalizedStringResource {
            "Broadcast input to every SSH session in this workspace — ⌘B"
        }

        public static var clearHistoryWarning: LocalizedStringResource {
            "This permanently removes all connection history."
        }

        public static var clearHostHistoryWarning: LocalizedStringResource {
            "This removes all connection history for this Host."
        }

        public static var clearRecentConnectionsConfirmation: LocalizedStringResource {
            "Clear Recent Connections?"
        }

        public static var closeAllWorkspaces: LocalizedStringResource {
            "Close All Workspaces"
        }

        public static var closeOthers: LocalizedStringResource {
            "Close Others"
        }

        public static var closeOtherWorkspaces: LocalizedStringResource {
            "Close Other Workspaces"
        }

        public static var closePane: LocalizedStringResource {
            "Close pane"
        }

        public static var closeWorkspace: LocalizedStringResource {
            "Close Workspace"
        }

        public static var closeWorkspaceClickToCloseTheOthers: LocalizedStringResource {
            "Close Workspace — ⌥-click to close the others"
        }

        public static var commandInserted: LocalizedStringResource {
            "Command Inserted"
        }

        public static var connectOnce: LocalizedStringResource {
            "Connect Once"
        }

        public static func copyTo(_ hostName: String) -> LocalizedStringResource {
            "Copy to \(hostName)"
        }

        public static var doubleClickToRename: LocalizedStringResource {
            "Double-click to rename"
        }

        public static var dragAnSshTerminalOrSftpBrowserHere: LocalizedStringResource {
            "Drag an SSH terminal or SFTP browser here."
        }

        public static var dragToMoveThisPaneDoubleClickToRename: LocalizedStringResource {
            "Drag to move this pane, double-click to rename"
        }

        public static var duplicateInNewWorkspace: LocalizedStringResource {
            "Duplicate in New Workspace"
        }

        public static var emptyPane: LocalizedStringResource {
            "Empty Pane"
        }

        public static var find: LocalizedStringResource {
            "Find"
        }

        public static var generateCommand: LocalizedStringResource {
            "Generate Command"
        }

        public static var generatingCommand: LocalizedStringResource {
            "Generating Command"
        }

        public static var helloIMTermind: LocalizedStringResource {
            "Hello, I'm Termind."
        }

        public static var moveWorkspaceToNewWindow: LocalizedStringResource {
            "Move Workspace to New Window"
        }

        public static var navigator: LocalizedStringResource {
            "Navigator"
        }

        public static var nextLocation: LocalizedStringResource {
            "Next Location"
        }

        public static var nextMatch: LocalizedStringResource {
            "Next Match"
        }

        public static func noHostsOrWorkspaceTemplatesMatch(_ query: String) -> LocalizedStringResource {
            "No hosts or Workspace templates match “\(query)”."
        }

        public static var noWorkspaces: LocalizedStringResource {
            "No Workspaces"
        }

        public static var notSaved: LocalizedStringResource {
            "Not saved"
        }

        public static var paneName: LocalizedStringResource {
            "Pane Name"
        }

        public static func panes(_ count: Int) -> LocalizedStringResource {
            "\(count) panes"
        }

        public static var pressReturnToRun: LocalizedStringResource {
            "Press Return to Run"
        }

        public static var previousLocation: LocalizedStringResource {
            "Previous Location"
        }

        public static var previousMatch: LocalizedStringResource {
            "Previous Match"
        }

        public static var recents: LocalizedStringResource {
            "Recents"
        }

        public static var resetName: LocalizedStringResource {
            "Reset Name"
        }

        public static var saveWorkspaceTemplate: LocalizedStringResource {
            "Save Workspace Template"
        }

        public static var saved: LocalizedStringResource {
            "Saved"
        }

        public static var searchHostsOrTemplatesOrTypeSshUserHost: LocalizedStringResource {
            "Search hosts or templates, or type ssh user@host"
        }

        public static var separatePanes: LocalizedStringResource {
            "Separate Panes"
        }

        public static var splitDown: LocalizedStringResource {
            "Split Down"
        }

        public static var splitRight: LocalizedStringResource {
            "Split Right"
        }

        public static var sshAndSftpWithAnAssistantAtHand: LocalizedStringResource {
            "SSH and SFTP, with an assistant at hand."
        }

        public static var telnetDoesNotSupportFileUpload: LocalizedStringResource {
            "Telnet does not support file upload."
        }

        public static var theEditedCopyUsesADifferentFormat: LocalizedStringResource {
            "The edited copy uses a different format"
        }

        public static var theFocusedShellHasNotReportedItsCurrentDirectory: LocalizedStringResource {
            "The focused shell has not reported its current directory."
        }

        public static var theSftpChannelIsNotConnected: LocalizedStringResource {
            "The SFTP channel is not connected."
        }

        public static var thisMayTakeAMoment: LocalizedStringResource {
            "This May Take a Moment"
        }

        public static var thisWorkspaceCanNoLongerBeSavedAsATemplate: LocalizedStringResource {
            "This Workspace can no longer be saved as a template."
        }

        public static var unavailableHost: LocalizedStringResource {
            "Unavailable Host"
        }

        public static func unavailableHostsWereOpenedAsEmptyPanes(_ missingHosts: Int) -> LocalizedStringResource {
            "\(missingHosts) unavailable hosts were opened as empty panes."
        }

        public static var updateWorkspaceTemplate: LocalizedStringResource {
            "Update Workspace Template"
        }

        public static var uploadFailed: LocalizedStringResource {
            "Upload Failed"
        }

        public static func uploadTo(_ host: String) -> LocalizedStringResource {
            "Upload to \(host)"
        }

        public static var useConnectToStartAWorkspace: LocalizedStringResource {
            "Use Connect to start a workspace."
        }

        public static var whatDoYouFeelLikeDoingConfirmation: LocalizedStringResource {
            "What do you feel like doing?"
        }

        public static var whatWouldYouLikeToDoConfirmation: LocalizedStringResource {
            "What would you like to do?"
        }

        public static var workspace: LocalizedStringResource {
            "Workspace"
        }

        public static var workspaceName: LocalizedStringResource {
            "Workspace Name"
        }

        public static var workspaceTemplates: LocalizedStringResource {
            "Workspace Templates"
        }

        public static var commandWithEaseStayInControl: LocalizedStringResource {
            "Command with ease, stay in control."
        }

        public static var cancelOperation: LocalizedStringResource {
            "Cancel operation"
        }

        public static var closeWindow: LocalizedStringResource {
            "Close Window"
        }

        public static var closeAllWindows: LocalizedStringResource {
            "Close All Windows"
        }

        public static var connectionLinkFailed: LocalizedStringResource {
            "Connection Link Failed"
        }

        public static var copyPath: LocalizedStringResource {
            "Copy Path"
        }

        public static var hideSessionDetails: LocalizedStringResource {
            "Hide Session Details"
        }

        public static var lastWorkspace: LocalizedStringResource {
            "Last Workspace"
        }

        public static var nextWorkspace: LocalizedStringResource {
            "Next Workspace"
        }

        public static var openTelnetConnectionConfirmation: LocalizedStringResource {
            "Open Telnet Connection?"
        }

        public static func openDirectoryWithTransportHelp(_ name: String) -> LocalizedStringResource {
            "Open current directory with \(name) — right-click for more options"
        }

        public static var previousWorkspace: LocalizedStringResource {
            "Previous Workspace"
        }

        public static var showSessionDetails: LocalizedStringResource {
            "Show Session Details"
        }

        public static var working: LocalizedStringResource {
            "Working"
        }

        public static var workspaceTemplate: LocalizedStringResource {
            "Workspace Template"
        }

        public static var workspaceUnavailable: LocalizedStringResource {
            "Workspace Unavailable"
        }

        public static func numberedWorkspace(_ number: Int) -> LocalizedStringResource {
            "Workspace \(number)"
        }

        public static var inCurrentWorkspace: LocalizedStringResource {
            "in Current Workspace"
        }

        public static var inNewWorkspace: LocalizedStringResource {
            "in New Workspace"
        }

        public static var commandGeneratorShellRequirement: LocalizedStringResource {
            "Command Generator requires a supported shell prompt with Shell Integration enabled."
        }

        public static var batchCommandGeneratorShellRequirement: LocalizedStringResource {
            "Command Generator requires every target to be at a supported shell prompt with Shell Integration enabled."
        }

        public static var commandGenerationFailed: LocalizedStringResource {
            "Couldn't generate command"
        }

        public static var supportedSSHOptions: LocalizedStringResource {
            "SSH options: -p port, -l user, -J jump; -o HostName, User, Port, ProxyJump."
        }

        public static var restoreWorkspacesFailure: LocalizedStringResource {
            "Saved workspaces could not be restored. The saved data has been kept."
        }

        public static var unavailableWorkspaceExplanation: LocalizedStringResource {
            "This workspace is no longer available. It may have ended, its host may have been removed, or an earlier app version may not have saved it."
        }

        public static var workspaceChangesCouldNotBeSavedForTheNextLaunch: LocalizedStringResource {
            "Workspace changes could not be saved for the next launch."
        }

        public static var newWindow: LocalizedStringResource {
            "New Window"
        }
        public static var reopenClosedWindow: LocalizedStringResource {
            "Reopen Last Closed Window"
        }
        public static var reopenClosedWorkspace: LocalizedStringResource {
            "Reopen Last Closed Workspace"
        }
    }
}
