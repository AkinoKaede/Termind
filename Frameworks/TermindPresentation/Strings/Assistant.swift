import Foundation

extension AppStrings {
    public nonisolated enum Assistant {
        public static var terminalActivity: LocalizedStringResource { "terminal" }
        public static var terminalsActivity: LocalizedStringResource { "terminals" }
        public static var listTerminals: LocalizedStringResource { "List terminals" }
        public static var readTerminal: LocalizedStringResource { "Read terminal" }
        public static func readTerminal(_ name: String) -> LocalizedStringResource { "Read terminal \(name)" }
        public static var terminalName: LocalizedStringResource { "Terminal name" }
        public static var paneID: LocalizedStringResource { "Pane ID" }
        public static var activeTerminal: LocalizedStringResource { "Active in window" }
        public static var currentTerminal: LocalizedStringResource { "Current in Assistant window" }
        public static var noOpenTerminals: LocalizedStringResource { "No open terminals" }
        public static var permissions: LocalizedStringResource { "Permissions" }
        public static var chatsSearchScope: LocalizedStringResource { "chats" }
        public static var memorySearchScope: LocalizedStringResource { "memory" }
        public static var userProfileSearchScope: LocalizedStringResource { "user profile" }

        public static func searching(_ query: String, in scope: String) -> LocalizedStringResource {
            "Searching \(query) in \(scope)"
        }

        public static func searched(_ query: String, in scope: String) -> LocalizedStringResource {
            "Searched \(query) in \(scope)"
        }

        public static var addAttachment: LocalizedStringResource {
            "Add Attachment"
        }

        public static var addContext: LocalizedStringResource {
            "Add context"
        }

        public static var agentError: LocalizedStringResource {
            "Agent error"
        }

        public static var agent: LocalizedStringResource {
            "Agent"
        }

        public static func agentFrom(_ title: String) -> LocalizedStringResource {
            "Agent from \(title)"
        }

        public static var chatDetailsUnavailable: LocalizedStringResource {
            "Chat details unavailable"
        }

        public static var allowCameraAccessInSettingsToTakeAPhoto: LocalizedStringResource {
            "Allow camera access in Settings to take a photo."
        }

        public static var allowOnce: LocalizedStringResource {
            "Allow Once"
        }

        public static var alwaysAskForApprovalBeforeProtectedActions: LocalizedStringResource {
            "Always ask for approval before protected actions"
        }

        public static var alwaysIncluded: LocalizedStringResource {
            "Always included"
        }

        public static var answer: LocalizedStringResource {
            "Answer"
        }

        public static var approvalRequired: LocalizedStringResource {
            "Approval required"
        }

        public static var archive: LocalizedStringResource {
            "Archive"
        }

        public static var archived: LocalizedStringResource {
            "Archived"
        }

        public static var archivedConversationsAreReadOnly: LocalizedStringResource {
            "Archived conversations are read-only."
        }

        public static func armedSkillHelp(_ name: String) -> LocalizedStringResource {
            "\(name) will be loaded for this message — click to remove"
        }

        public static var askAQuestionOrDescribeWhatYouWantToDo: LocalizedStringResource {
            "Ask a question or describe what you want to do."
        }

        public static var attachToChat: LocalizedStringResource {
            "Attach to Chat"
        }

        public static var attachedContext: LocalizedStringResource {
            "Attached context"
        }

        public static var attachmentError: LocalizedStringResource {
            "Attachment Error"
        }

        public static var autoReviewingInProgress: LocalizedStringResource {
            "Auto-reviewing in progress"
        }

        public static func automaticReview(risk: String, reason: String) -> LocalizedStringResource {
            "Auto-reviewing: \(risk) — \(reason)"
        }

        public static var backToChats: LocalizedStringResource {
            "Back to Chats"
        }

        public static var camera: LocalizedStringResource {
            "Camera"
        }

        public static var cancelImport: LocalizedStringResource {
            "Cancel import"
        }

        public static func cancelImporting(_ name: String) -> LocalizedStringResource {
            "Cancel importing \(name)"
        }

        public static var cancelTranscription: LocalizedStringResource {
            "Cancel Transcription"
        }

        public static var chats: LocalizedStringResource {
            "Chats"
        }

        public static var chatsYouArchiveWillAppearHere: LocalizedStringResource {
            "Chats you archive will appear here."
        }

        public static var collapsed: LocalizedStringResource {
            "Collapsed"
        }

        public static var commands: LocalizedStringResource {
            "Commands"
        }

        public static var compactingContext: LocalizedStringResource {
            "Compacting context"
        }

        public static var compactionExplanation: LocalizedStringResource {
            "Earlier turns are summarized for the model. Nothing was deleted."
        }

        public static func compactionSummary(summarized: String, retained: String) -> LocalizedStringResource {
            "Compacted — \(summarized) summarized to \(retained)"
        }

        public static var configureModelProviders: LocalizedStringResource {
            "Configure Model Providers"
        }

        public static var context: LocalizedStringResource {
            "Context"
        }

        public static var conversationName: LocalizedStringResource {
            "Conversation Name"
        }

        public static var conversations: LocalizedStringResource {
            "Conversations"
        }

        public static var couldnTOpenAttachment: LocalizedStringResource {
            "Couldn’t Open Attachment"
        }

        public static var deleteConversation: LocalizedStringResource {
            "Delete Conversation"
        }

        public static var deleteConversationConfirmation: LocalizedStringResource {
            "Delete Conversation?"
        }

        public static var discarded: LocalizedStringResource {
            "Discarded"
        }

        public static var droppedImage: LocalizedStringResource {
            "Dropped image"
        }

        public static var editMessage: LocalizedStringResource {
            "Edit Message"
        }

        public static var effort: LocalizedStringResource {
            "Effort"
        }

        public static var expanded: LocalizedStringResource {
            "Expanded"
        }

        public static var files: LocalizedStringResource {
            "Files"
        }

        public static var filesAndImages: LocalizedStringResource {
            "Files and images"
        }

        public static func firstQuestionOf(_ count: Int) -> LocalizedStringResource {
            "1 of \(count)"
        }

        public static var fork: LocalizedStringResource {
            "Fork"
        }

        public static var forkConversation: LocalizedStringResource {
            "Fork Conversation"
        }

        public static var hideDetails: LocalizedStringResource {
            "Hide details"
        }

        public static var hideThePlan: LocalizedStringResource {
            "Hide the plan"
        }

        public static var hideTools: LocalizedStringResource {
            "Hide tools"
        }

        public static var hideWork: LocalizedStringResource {
            "Hide work"
        }

        public static var implement: LocalizedStringResource {
            "Implement"
        }

        public static var implemented: LocalizedStringResource {
            "Implemented"
        }

        public static var model: LocalizedStringResource {
            "Model"
        }

        public static func modelAccessibilityLabel(_ name: String) -> LocalizedStringResource {
            "Model \(name)"
        }

        public static func modelAndEffortAccessibilityLabel(name: String, effort: String) -> LocalizedStringResource {
            "Model \(name), effort \(effort)"
        }

        public static var newConversation: LocalizedStringResource {
            "New Conversation"
        }

        public static var noApplicationIsAvailableToOpenThisAttachment: LocalizedStringResource {
            "No application is available to open this attachment."
        }

        public static var noArchivedChats: LocalizedStringResource {
            "No Archived Chats"
        }

        public static var noConversations: LocalizedStringResource {
            "No Conversations"
        }

        public static var noModel: LocalizedStringResource {
            "No model"
        }

        public static var noModelAccessibilityLabel: LocalizedStringResource {
            "Model, no model configured"
        }

        public static var noModelConfigured: LocalizedStringResource {
            "No model configured"
        }

        public static var noModelsConfigured: LocalizedStringResource {
            "No models configured"
        }

        public static var onlyAskForActionsDetectedAsPotentiallyUnsafe: LocalizedStringResource {
            "Only ask for actions detected as potentially unsafe"
        }

        public static func `open`(_ label: String) -> LocalizedStringResource {
            "Open \(label)"
        }

        public static var openFullScreen: LocalizedStringResource {
            "Open Full Screen"
        }

        public static var openSystemSettings: LocalizedStringResource {
            "Open System Settings"
        }

        public static var outputShortenedForDisplay: LocalizedStringResource {
            "Output shortened for display"
        }

        public static var outputTruncated: LocalizedStringResource {
            "Output truncated"
        }

        public static var pastedImage: LocalizedStringResource {
            "Pasted image"
        }

        public static func permission(_ displayName: String) -> LocalizedStringResource {
            "Permission, \(displayName)"
        }

        public static func permissionNamed(_ displayName: String) -> LocalizedStringResource {
            "Permission: \(displayName)"
        }

        public static var photo: LocalizedStringResource {
            "Photo"
        }

        public static var photos: LocalizedStringResource {
            "Photos"
        }

        public static var pin: LocalizedStringResource {
            "Pin"
        }

        public static var pinned: LocalizedStringResource {
            "Pinned"
        }

        public static var plan: LocalizedStringResource {
            "Plan"
        }

        public static var planModeClickToTurnOff: LocalizedStringResource {
            "Plan mode — click to turn off"
        }

        public static var planModeOnTurnOff: LocalizedStringResource {
            "Plan mode on, turn off"
        }

        public static func questionOf(current: Int, total: Int) -> LocalizedStringResource {
            "Question \(current) of \(total)"
        }

        public static var queueForTheRunningAgent: LocalizedStringResource {
            "Queue for the running agent — ⏎"
        }

        public static var queuedMessages: LocalizedStringResource {
            "Queued messages"
        }

        public static var reasoningProgress: LocalizedStringResource {
            "Reasoning…"
        }

        public static var recommended: LocalizedStringResource {
            "Recommended"
        }

        public static var recording: LocalizedStringResource {
            "Recording"
        }

        public static var removeAttachment: LocalizedStringResource {
            "Remove attachment"
        }

        public static var replyToKeepPlanning: LocalizedStringResource {
            "Reply to keep planning"
        }

        public static func run(_ activity: String) -> LocalizedStringResource {
            "Run \(activity)"
        }

        public static var runADestructiveCommandConfirmation: LocalizedStringResource {
            "Run a destructive command?"
        }

        public static var send: LocalizedStringResource {
            "Send"
        }

        public static var sendAMessageBelowToStartOne: LocalizedStringResource {
            "Send a message below to start one."
        }

        public static var sendLabel: LocalizedStringResource {
            "Send — ⌘⏎"
        }

        public static var showArchive: LocalizedStringResource {
            "Show Archive"
        }

        public static var showDetails: LocalizedStringResource {
            "Show details"
        }

        public static var showFailureDetails: LocalizedStringResource {
            "Show failure details"
        }

        public static var showLess: LocalizedStringResource {
            "Show less"
        }

        public static var showMore: LocalizedStringResource {
            "Show more"
        }

        public static var showThePlan: LocalizedStringResource {
            "Show the plan"
        }

        public static var showTools: LocalizedStringResource {
            "Show tools"
        }

        public static var showWork: LocalizedStringResource {
            "Show work"
        }

        public static func skillArmedRemove(_ name: String) -> LocalizedStringResource {
            "Skill \(name) armed, remove"
        }

        public static var startAConversation: LocalizedStringResource {
            "Start a Conversation"
        }

        public static var steering: LocalizedStringResource {
            "Steering"
        }

        public static var stopCurrentRun: LocalizedStringResource {
            "Stop current run — ⌘."
        }

        public static var stopRecording: LocalizedStringResource {
            "Stop Recording"
        }

        public static var suggestedCommand: LocalizedStringResource {
            "Suggested Command"
        }

        public static var takeThisBackAndEditIt: LocalizedStringResource {
            "Take this back and edit it"
        }

        public static var thinkingProgress: LocalizedStringResource {
            "Thinking…"
        }

        public static var thisRunWasInterruptedAndWasNotResumed: LocalizedStringResource {
            "This run was interrupted and was not resumed."
        }

        public static func through(label: String, name: String) -> LocalizedStringResource {
            "\(label) through \(name)"
        }

        public static func throughEffort(label: String, name: String, displayName: String) -> LocalizedStringResource {
            "\(label) through \(name) · \(displayName) effort"
        }

        public static var transcribe: LocalizedStringResource {
            "Transcribe"
        }

        public static var transcribeWithAppleSpeech: LocalizedStringResource {
            "Transcribe with Apple Speech"
        }

        public static var transcribing: LocalizedStringResource {
            "Transcribing"
        }

        public static var transcriptionFailed: LocalizedStringResource {
            "Transcription Failed"
        }

        public static var unarchive: LocalizedStringResource {
            "Unarchive"
        }

        public static var unpin: LocalizedStringResource {
            "Unpin"
        }

        public static var unqueueMessage: LocalizedStringResource {
            "Unqueue message"
        }

        public static var unrestrictedToTheInternetAndAnyFilesOnYourHosts: LocalizedStringResource {
            "Unrestricted to the Internet and any files on your hosts"
        }

        public static var voiceInput: LocalizedStringResource {
            "Voice Input"
        }

        public static var workingProgress: LocalizedStringResource {
            "Working…"
        }

        public static var chat: LocalizedStringResource {
            "Chat"
        }

        public static var conversationOperationFailed: LocalizedStringResource {
            "Conversation Operation Failed"
        }

        public static var newChat: LocalizedStringResource {
            "New Chat"
        }

        public static var prompt: LocalizedStringResource {
            "Ask anything…"
        }

        public static var compactionFailed: LocalizedStringResource {
            "Couldn’t compact context"
        }

        public static var deleteStagedConversationWarning: LocalizedStringResource {
            "Permanently delete this conversation and its staged files?"
        }

        public static var otherAnswer: LocalizedStringResource {
            "Something else…"
        }

        public static var visionModelRequirement: LocalizedStringResource {
            "The selected model cannot read images. Choose a vision-capable model before sending."
        }

        public static var deleteConversationWarning: LocalizedStringResource {
            "This permanently removes the conversation and its scratch files."
        }

        public static var askAssistant: LocalizedStringResource {
            "Ask Assistant"
        }
        public static var executeADestructiveCommandConfirmation: LocalizedStringResource {
            "Execute a destructive command?"
        }
        public static var showAssistant: LocalizedStringResource {
            "Show Assistant"
        }
    }
}
