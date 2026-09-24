import Foundation

extension AppStrings {
    public nonisolated enum Onboarding {
        public static var waitingForWindow: LocalizedStringResource { "Waiting for an active window." }

        public static var pathNavigationExplanation: LocalizedStringResource {
            "Click the path to open the same directory in another session. Right-click for more options."
        }

        public static var sshPathExplanation: LocalizedStringResource {
            "Click the path to open this directory with SSH. Right-click to copy it or open it in a new workspace."
        }

        public static var dismiss: LocalizedStringResource {
            "Dismiss"
        }

        public static var dismissOnboardingTip: LocalizedStringResource {
            "Dismiss onboarding tip"
        }

        public static var generateACommandWithAi: LocalizedStringResource {
            "Generate a command with AI"
        }

        public static var gotIt: LocalizedStringResource {
            "Got It"
        }

        public static func onboarding(_ title: String) -> LocalizedStringResource {
            "Onboarding: \(title)"
        }

        public static var openIt: LocalizedStringResource {
            "Open It"
        }

        public static var pressPToSearchPagesWorkspacesHostsAndCommands: LocalizedStringResource {
            "Press ⌘P to search pages, workspaces, hosts, and commands."
        }

        public static var quicklyOpenAnything: LocalizedStringResource {
            "Quickly open anything"
        }

        public static var tryIt: LocalizedStringResource {
            "Try It"
        }

        public static var commandGeneratorExplanation: LocalizedStringResource {
            "Type what you want to do at the shell prompt, then press ⌘I. The generated command is inserted but never run automatically."
        }

        public static var yourCurrentPathIsAnAction: LocalizedStringResource {
            "Your current path is an action"
        }

        public static var statusBarPath: LocalizedStringResource { "Status Bar Path" }
        public static var commandGenerator: LocalizedStringResource { "Command Generator" }
        public static var completed: LocalizedStringResource { "Completed" }
        public static var pending: LocalizedStringResource { "Pending" }
        public static var previewing: LocalizedStringResource { "Previewing" }
        public static var waitingForContext: LocalizedStringResource { "Waiting for Context" }
        public static var dismissCurrentPresentation: LocalizedStringResource {
            "Close the current sheet, popover, or command palette."
        }
        public static var waitingForActiveWindow: LocalizedStringResource { "Waiting for an active app window." }
        public static var pathPreviewRequirement: LocalizedStringResource {
            "Open a connected SSH session or SFTP channel with an expanded Status Bar and a known path."
        }
        public static var commandPreviewRequirement: LocalizedStringResource {
            "Focus a supported SSH shell prompt with Shell Integration and a configured Command Generator."
        }
        public static var cancelPreview: LocalizedStringResource { "Cancel Preview" }
        public static var resetAll: LocalizedStringResource { "Reset All Onboarding" }
        public static var previewExplanation: LocalizedStringResource {
            "Preview bypasses completion and ordering but waits for a real eligible context. Preview actions never change completion state."
        }
        public static var title: LocalizedStringResource { "Onboarding" }
        public static var preview: LocalizedStringResource { "Preview" }
        public static var reset: LocalizedStringResource { "Reset" }
        public static var developerPreview: LocalizedStringResource { "Developer Preview" }
    }
}
