import Foundation

extension AppStrings {
    public nonisolated enum Settings {
        public static var devices: LocalizedStringResource { "Devices" }
        public static var optionalSync: LocalizedStringResource { "Optional Sync" }
        public static var signInToSync: LocalizedStringResource { "Sign in to iCloud to sync." }

        public static var developer: LocalizedStringResource { "Developer" }

        public static var abilities: LocalizedStringResource {
            "Abilities"
        }

        public static var accessEnds: LocalizedStringResource {
            "Access Ends"
        }

        public static func add(_ count: Int) -> LocalizedStringResource {
            "Add \(count)"
        }

        public static var addAProviderToConfigureAiModels: LocalizedStringResource {
            "Add a provider to configure AI models."
        }

        public static var addAUrlThenPressFetch: LocalizedStringResource {
            "Add a URL, then press Fetch"
        }

        public static var addAnMcpServerToConnectRemoteTools: LocalizedStringResource {
            "Add an MCP server to connect remote tools."
        }

        public static var addHeader: LocalizedStringResource {
            "Add Header"
        }

        public static var addModel: LocalizedStringResource {
            "Add Model"
        }

        public static var addProvider: LocalizedStringResource {
            "Add Provider"
        }

        public static var addSelected: LocalizedStringResource {
            "Add Selected"
        }

        public static var addSkill: LocalizedStringResource {
            "Add Skill"
        }

        public static var added: LocalizedStringResource {
            "Added"
        }

        public static var addedManually: LocalizedStringResource {
            "Added Manually"
        }

        public static var ai: LocalizedStringResource {
            "AI"
        }

        public static var aiProviderUsageAndChargesAreSeparateFromTermindPro: LocalizedStringResource {
            "AI provider usage and charges are separate from Termind Pro."
        }

        public static var annualFamilyShared: LocalizedStringResource {
            "Annual · Family Shared"
        }

        public static var anotherMcpServerAlreadyUsesThisId: LocalizedStringResource {
            "Another MCP server already uses this ID."
        }

        public static var anotherSkillAlreadyUsesThisName: LocalizedStringResource {
            "Another skill already uses this name."
        }

        public static var apiKey: LocalizedStringResource {
            "API Key"
        }

        public static var app: LocalizedStringResource {
            "App"
        }

        public static var appearance: LocalizedStringResource {
            "Appearance"
        }

        public static var approve: LocalizedStringResource {
            "Approve"
        }

        public static var ask: LocalizedStringResource {
            "Ask"
        }

        public static var automaticFromModelCatalog: LocalizedStringResource {
            "Automatic from model catalog"
        }

        public static var automaticallyRenameWorkspaces: LocalizedStringResource {
            "Automatically Rename Workspaces"
        }

        public static var availableModels: LocalizedStringResource {
            "Available Models"
        }

        public static var basics: LocalizedStringResource {
            "Basics"
        }

        public static var bearerToken: LocalizedStringResource {
            "Bearer Token"
        }

        public static var callHistory: LocalizedStringResource {
            "Call History"
        }

        public static var callsAppearHereAfterAnMcpClientInvokesATool: LocalizedStringResource {
            "Calls appear here after an MCP client invokes a tool."
        }

        public static var can: LocalizedStringResource {
            "Can"
        }

        public static var chooseASkillMdFileOrAFolderThatContainsOne: LocalizedStringResource {
            "Choose a SKILL.md file, or a folder that contains one."
        }

        public static var clearCallHistoryConfirmation: LocalizedStringResource {
            "Clear Call History?"
        }

        public static var clearFilter: LocalizedStringResource {
            "Clear filter"
        }

        public static var clearKey: LocalizedStringResource {
            "Clear Key"
        }

        public static var clearToken: LocalizedStringResource {
            "Clear Token"
        }

        public static var closeModelDetails: LocalizedStringResource {
            "Close model details"
        }

        public static var conflict: LocalizedStringResource {
            "Conflict"
        }

        public static var connectClients: LocalizedStringResource {
            "Connect Clients"
        }

        public static var connectToRemoteMcpServersOverHttp: LocalizedStringResource {
            "Connect to remote MCP servers over HTTP."
        }

        public static var connectToSeeWhatThisServerOffers: LocalizedStringResource {
            "Connect to see what this server offers."
        }

        public static var connectedClients: LocalizedStringResource {
            "Connected clients"
        }

        public static var connection: LocalizedStringResource {
            "Connection"
        }

        public static var connections: LocalizedStringResource {
            "Connections"
        }

        public static var contextWindow: LocalizedStringResource {
            "Context Window"
        }

        public static var copyAddCommand: LocalizedStringResource {
            "Copy Add Command"
        }

        public static var copyOnSelection: LocalizedStringResource {
            "Copy on Selection"
        }

        public static var credential: LocalizedStringResource {
            "Credential"
        }

        public static var customConfiguration: LocalizedStringResource {
            "Custom Configuration"
        }

        public static var customHeader: LocalizedStringResource {
            "Custom Header"
        }

        public static var customHeaders: LocalizedStringResource {
            "Custom Headers"
        }

        public static var customMapping: LocalizedStringResource {
            "Custom mapping"
        }

        public static var dark: LocalizedStringResource {
            "Dark"
        }

        public static var darkCustomConfiguration: LocalizedStringResource {
            "Dark Custom Configuration"
        }

        public static var deleteAllLoggingFilesConfirmation: LocalizedStringResource {
            "Delete all logging files?"
        }

        public static var deleteServer: LocalizedStringResource {
            "Delete Server"
        }

        public static var derivedFromTheTitle: LocalizedStringResource {
            "Derived from the title"
        }

        public static var description: LocalizedStringResource {
            "Description"
        }

        public static var developmentAccess: LocalizedStringResource {
            "Development Access"
        }

        public static var disabled: LocalizedStringResource {
            "Disabled"
        }

        public static func discoveredTools(server: String, count: Int) -> LocalizedStringResource {
            "\(server) — \(count) tools"
        }

        public static var dismissError: LocalizedStringResource {
            "Dismiss error"
        }

        public static var draft: LocalizedStringResource {
            "Draft"
        }

        public static var duplicateMCPNamespaces: LocalizedStringResource {
            "Some MCP servers have duplicate namespaces and are paused. Edit their namespace IDs to resolve the conflict."
        }

        public static var duplicateSkillNames: LocalizedStringResource {
            "Some skills have duplicate names and are paused. Rename them to resolve the conflict."
        }

        public static func edit(_ displayTitle: String) -> LocalizedStringResource {
            "Edit \(displayTitle)"
        }

        public static var editConfiguration: LocalizedStringResource {
            "Edit Configuration"
        }

        public static var editCustomConfiguration: LocalizedStringResource {
            "Edit Custom Configuration"
        }

        public static var enable: LocalizedStringResource {
            "Enable"
        }

        public static func enableNamed(_ displayTitle: String) -> LocalizedStringResource {
            "Enable \(displayTitle)"
        }

        public static var enableWebSearch: LocalizedStringResource {
            "Enable Web Search"
        }

        public static var enterAnHttpOrHttpsMcpUrl: LocalizedStringResource {
            "Enter an HTTP or HTTPS MCP URL."
        }

        public static var exactModelIdSuchAsGpt54: LocalizedStringResource {
            "Exact model ID, such as gpt-5.4"
        }

        public static var expired: LocalizedStringResource {
            "Expired"
        }

        public static var exposedTools: LocalizedStringResource {
            "Exposed Tools"
        }

        public static var fetch: LocalizedStringResource {
            "Fetch"
        }

        public static var fetchAvailableModelsFromTheEndpoint: LocalizedStringResource {
            "Fetch available models from the endpoint."
        }

        public static func fetched(_ value: String) -> LocalizedStringResource {
            "Fetched \(value)"
        }

        public static var fileIsNotValidUtf8Text: LocalizedStringResource {
            "File is not valid UTF-8 text"
        }

        public static var filterByClientToolHostOrArgument: LocalizedStringResource {
            "Filter by client, tool, host or argument"
        }

        public static var followSystem: LocalizedStringResource {
            "Follow System"
        }

        public static var font: LocalizedStringResource {
            "Font"
        }

        public static var generateATokenToCopyClientSetupCommands: LocalizedStringResource {
            "Generate a token to copy client setup commands."
        }

        public static var generateToken: LocalizedStringResource {
            "Generate Token"
        }

        public static var ghostty: LocalizedStringResource {
            "Ghostty"
        }

        public static var gracePeriodEnds: LocalizedStringResource {
            "Grace Period Ends"
        }

        public static var headerName: LocalizedStringResource {
            "Header name"
        }

        public static var headerValue: LocalizedStringResource {
            "Header value"
        }

        public static var hermesMemory: LocalizedStringResource {
            "Hermes Memory"
        }

        public static var memoryNotes: LocalizedStringResource {
            "Memory Notes"
        }

        public static var userProfile: LocalizedStringResource {
            "User Profile"
        }

        public static var hermesPolicyDescription: LocalizedStringResource {
            "Saved memory stays on this device. The assistant searches it when earlier preferences or decisions are relevant."
        }

        public static var hermesLearningDescription: LocalizedStringResource {
            "Automatic learning reviews completed requests after 10 turns or 15 tool calls. Corrections are reviewed sooner. Your configured model may incur API charges."
        }

        public static var hermesDestroyDescription: LocalizedStringResource {
            "Delete saved memory, learning progress, and search indexes, then turn off Memory. Skills and chat history are kept. Re-enabling Memory can rebuild memories from old chats."
        }

        public static func hermesMemoryUsage(entries: Int, characters: Int) -> LocalizedStringResource {
            "\(entries) entries · \(characters) characters"
        }

        public static var hideSecret: LocalizedStringResource {
            "Hide Secret"
        }

        public static var iCloudSync: LocalizedStringResource {
            "iCloud Sync"
        }

        public static var id: LocalizedStringResource {
            "ID"
        }

        public static var importFromFile: LocalizedStringResource {
            "Import from File"
        }

        public static var importSkill: LocalizedStringResource {
            "Import Skill"
        }

        public static var importedFrom: LocalizedStringResource {
            "Imported From"
        }

        public static var input: LocalizedStringResource {
            "Input"
        }

        public static var instructions: LocalizedStringResource {
            "Instructions"
        }

        public static var integration: LocalizedStringResource {
            "Integration"
        }

        public static var keepExistingKey: LocalizedStringResource {
            "Keep Existing Key"
        }

        public static var keepExistingToken: LocalizedStringResource {
            "Keep Existing Token"
        }

        public static var language: LocalizedStringResource {
            "Language"
        }

        public static func lastConnected(_ value: String) -> LocalizedStringResource {
            "Last connected \(value)"
        }

        public static var level: LocalizedStringResource {
            "Level"
        }

        public static var libssh2: LocalizedStringResource {
            "libssh2"
        }

        public static var light: LocalizedStringResource {
            "Light"
        }

        public static var lightCustomConfiguration: LocalizedStringResource {
            "Light Custom Configuration"
        }

        public static var limits: LocalizedStringResource {
            "Limits"
        }

        public static var logExportWarning: LocalizedStringResource {
            "Logs may contain private diagnostic information. Review where you send or save them."
        }

        public static var logSharingWarning: LocalizedStringResource {
            "Logs may contain private diagnostic information. Review them before sharing."
        }

        public static var logging: LocalizedStringResource {
            "Logging"
        }

        public static var logs: LocalizedStringResource {
            "Logs"
        }

        public static func longerThan(_ limit: String) -> LocalizedStringResource {
            "Longer than \(limit)."
        }

        public static var macOSIsWaitingForYouToAllowTermindInLoginItems: LocalizedStringResource {
            "macOS is waiting for you to allow Termind in Login Items."
        }

        public static var manageModels: LocalizedStringResource {
            "Manage Models"
        }

        public static var maxOutput: LocalizedStringResource {
            "Max Output"
        }

        public static var mcp: LocalizedStringResource {
            "MCP"
        }

        public static var mcpEndpointUrl: LocalizedStringResource {
            "MCP endpoint URL"
        }

        public static var mergeWithThisICloudAccount: LocalizedStringResource {
            "Merge with This iCloud Account"
        }

        public static var modelId: LocalizedStringResource {
            "Model ID"
        }

        public static var modelProviders: LocalizedStringResource {
            "Model Providers"
        }

        public static var models: LocalizedStringResource {
            "Models"
        }

        public static func modelsNamed(_ count: Int) -> LocalizedStringResource {
            "\(count) Models"
        }

        public static func modelsOffered(_ count: Int) -> LocalizedStringResource {
            "\(count) Models Offered"
        }

        public static var mouse: LocalizedStringResource {
            "Mouse"
        }

        public static var nameIsRequired: LocalizedStringResource {
            "Name is required."
        }

        public static var namespaceNameRequirement: LocalizedStringResource {
            "Name must produce an ID containing ASCII letters or numbers."
        }

        public static var needsAUrl: LocalizedStringResource {
            "Needs a URL"
        }

        public static var noDescription: LocalizedStringResource {
            "No description"
        }

        public static var noExternalCalls: LocalizedStringResource {
            "No external calls"
        }

        public static var noMatch: LocalizedStringResource {
            "No Match"
        }

        public static var noMcpServers: LocalizedStringResource {
            "No MCP Servers"
        }

        public static var noModels: LocalizedStringResource {
            "No Models"
        }

        public static var noModelsAvailable: LocalizedStringResource {
            "No Models Available"
        }

        public static var noModelsYet: LocalizedStringResource {
            "No Models Yet"
        }

        public static var noProviders: LocalizedStringResource {
            "No Providers"
        }

        public static var noSavedLogs: LocalizedStringResource {
            "No Saved Logs"
        }

        public static var noSavedLogsLabel: LocalizedStringResource {
            "No saved logs."
        }

        public static var noUrl: LocalizedStringResource {
            "No URL"
        }

        public static var notConnected: LocalizedStringResource {
            "Not Connected"
        }

        public static var openAtLogin: LocalizedStringResource {
            "Open at Login"
        }

        public static var openHiddenAtLogin: LocalizedStringResource {
            "Open Hidden at Login"
        }

        public static var openLoginItemsSettings: LocalizedStringResource {
            "Open Login Items Settings"
        }

        public static var openSSL: LocalizedStringResource {
            "OpenSSL"
        }

        public static var pasteOnRightClick: LocalizedStringResource {
            "Paste on Right-Click"
        }

        public static var permanentlyDeletesThisProviderItsKeyAndItsModels: LocalizedStringResource {
            "Permanently deletes this provider, its key, and its models."
        }

        public static var preferBuiltInWebSearch: LocalizedStringResource {
            "Prefer Built-in Web Search"
        }

        public static var providerDefault: LocalizedStringResource {
            "Provider default"
        }

        public static var providerDeleted: LocalizedStringResource {
            "Provider Deleted"
        }

        public static var rateOnTheAppStore: LocalizedStringResource {
            "Rate on the App Store"
        }

        public static var reasoningEffort: LocalizedStringResource {
            "Reasoning Effort"
        }

        public static func reasoningProviderValue(_ effort: String) -> LocalizedStringResource {
            "\(effort) provider value"
        }

        public static var relaunchNow: LocalizedStringResource {
            "Relaunch Now"
        }

        public static var removeHeader: LocalizedStringResource {
            "Remove header"
        }

        public static func removesTheSelectedModelsWouldReturnToAutomatic(_ names: String) -> LocalizedStringResource {
            "Removes the selected models. \(names) would return to Automatic."
        }

        public static var removesTheSelectedModelsYouCanFetchThemAgain: LocalizedStringResource {
            "Removes the selected models. You can fetch them again."
        }

        public static var renews: LocalizedStringResource {
            "Renews"
        }

        public static var replaceKey: LocalizedStringResource {
            "Replace Key"
        }

        public static var replaceToken: LocalizedStringResource {
            "Replace Token"
        }

        public static var resetToAutomatic: LocalizedStringResource {
            "Reset to Automatic"
        }

        public static var rotateToken: LocalizedStringResource {
            "Rotate Token"
        }

        public static var rotatingDisconnectsEveryActiveMcpSession: LocalizedStringResource {
            "Rotating disconnects every active MCP session."
        }

        public static func selectForBatchActions(_ label: String) -> LocalizedStringResource {
            "Select \(label) for batch actions"
        }

        public static var server: LocalizedStringResource {
            "Server"
        }

        public static var serverDeleted: LocalizedStringResource {
            "Server Deleted"
        }

        public static var shareLogging: LocalizedStringResource {
            "Share Logging"
        }

        public static var shellIntegration: LocalizedStringResource {
            "Shell Integration"
        }

        public static var showInAssistant: LocalizedStringResource {
            "Show in Assistant"
        }

        public static var showInMenuBar: LocalizedStringResource {
            "Show in Menu Bar"
        }

        public static var showSecret: LocalizedStringResource {
            "Show Secret"
        }

        public static var showTerminalTitleInMenuBar: LocalizedStringResource {
            "Show Terminal Title in Menu Bar"
        }

        public static var skill: LocalizedStringResource {
            "Skill"
        }

        public static var skillBodyExplanation: LocalizedStringResource {
            "Markdown. Returned whole when the assistant loads this skill."
        }

        public static var skillDeleted: LocalizedStringResource {
            "Skill Deleted"
        }

        public static var skillDescriptionExplanation: LocalizedStringResource {
            "What this does and when to use it. This is the only part the assistant sees until it loads the skill, so it decides whether the skill is used at all."
        }

        public static var skillExplanation: LocalizedStringResource {
            "A skill is a procedure the assistant loads when a task matches its description, and then follows. It never approves an action: commands, writes and transfers still ask exactly as they would otherwise."
        }

        public static var skills: LocalizedStringResource {
            "Skills"
        }

        public static var startup: LocalizedStringResource {
            "Startup"
        }

        public static var support: LocalizedStringResource {
            "Support"
        }

        public static var sync: LocalizedStringResource {
            "Sync"
        }

        public static var taiwanFlagAvailable: LocalizedStringResource {
            "Taiwan Flag Available"
        }

        public static var terminal: LocalizedStringResource {
            "Terminal"
        }

        public static var terminalConfigurationExplanation: LocalizedStringResource {
            "Termind uses [Ghostty](https://ghostty.org) as its terminal engine. Custom configuration uses [Ghostty's configuration format](https://ghostty.org/docs/config/reference)."
        }

        public static var termindConnectsDirectlyFromThisMacOverHttp: LocalizedStringResource {
            "Termind connects directly from this Mac over HTTP."
        }

        public static var testingProgress: LocalizedStringResource {
            "Testing…"
        }

        public static var theKeyIsStoredInThisMacSDataProtectionKeychain: LocalizedStringResource {
            "The key is stored in this Mac's Data Protection Keychain."
        }

        public static var theNewLanguageWillBeUsedAfterTermindRelaunches: LocalizedStringResource {
            "The new language will be used after Termind relaunches."
        }

        public static var theme: LocalizedStringResource {
            "Theme"
        }

        public static var thisConfigurationIsAvailableWithTermindPro: LocalizedStringResource {
            "This configuration is available with Termind Pro."
        }

        public static var thisPermanentlyRemovesAllSavedMcpCallRecords: LocalizedStringResource {
            "This permanently removes all saved MCP call records."
        }

        public static var token: LocalizedStringResource {
            "Token"
        }

        public static var toolApprovalExplanation: LocalizedStringResource {
            "Deny refuses the call. Ask uses the conversation's manual or automatic approval. Approve runs without approval."
        }

        public static var tools: LocalizedStringResource {
            "Tools"
        }

        public static func toolsNamed(_ count: Int) -> LocalizedStringResource {
            "\(count) tools"
        }

        public static var transport: LocalizedStringResource {
            "Transport"
        }

        public static var trialEnds: LocalizedStringResource {
            "Trial Ends"
        }

        public static var url: LocalizedStringResource {
            "URL"
        }

        public static var version: LocalizedStringResource {
            "Version"
        }

        public static var vertexAi: LocalizedStringResource {
            "Vertex AI"
        }

        public static var viewTermindPro: LocalizedStringResource {
            "View Termind Pro"
        }

        public static var waitingProgress: LocalizedStringResource {
            "Waiting…"
        }

        public static var webSearch: LocalizedStringResource {
            "Web Search"
        }

        public static var workspaceNumberingExplanation: LocalizedStringResource {
            "New Workspaces with the same Host name use the next number, regardless of protocol."
        }

        public static func wouldGoBackToAutomatic(_ names: String) -> LocalizedStringResource {
            "\(names) would go back to Automatic."
        }

        public static var modelDiscoveryRequiresURL: LocalizedStringResource {
            "Add a URL first. Models are listed from the endpoint's own address."
        }

        public static var headerStorageWarning: LocalizedStringResource {
            "Custom headers are stored as plain text. For secrets, use the bearer token field above."
        }

        public static var webSearchExplanation: LocalizedStringResource {
            "Every model searches Google, Bing, DuckDuckGo, and Yahoo from this Mac and reads result pages as Markdown."
        }

        public static var hermesSetupRequirement: LocalizedStringResource {
            "Hermes needs the server running during setup and may ask you to select tools."
        }

        public static var shellIntegrationExplanation: LocalizedStringResource {
            "Keeps the remote working directory current, records confirmed commands, and provides detected distribution, kernel, and architecture details to AI features."
        }

        public static var nativeAndFallbackSearchExplanation: LocalizedStringResource {
            "Models with provider-native search use it directly. Other models search Google, Bing, DuckDuckGo, and Yahoo from this Mac and read result pages as Markdown."
        }

        public static var modelPickerVisibilityExplanation: LocalizedStringResource {
            "Offer this model in the Assistant model picker and /model command."
        }

        public static var directProviderConnectionExplanation: LocalizedStringResource {
            "Requests go directly from this Mac to each endpoint, not through an SSH host."
        }

        public static var rightClickPasteExplanation: LocalizedStringResource {
            "Right-click to paste. Hold Option to keep the usual right-click behavior. Applications that capture the mouse keep their mouse controls."
        }

        public static var mcpSetupExplanation: LocalizedStringResource {
            "Run the copied command in a terminal on this Mac. Enable the server before connecting."
        }

        public static var modelSelectionExplanation: LocalizedStringResource {
            "Select a model to edit it. Use the checkboxes to test or delete models."
        }

        public static var modelTestExplanation: LocalizedStringResource {
            "Sends each selected model a short prompt and shows the response."
        }

        public static var bearerTokenExplanation: LocalizedStringResource {
            "Sent in the Authorization header. Custom headers below are stored as plain text."
        }

        public static var toolAuditStorageExplanation: LocalizedStringResource {
            "Stores commands, paths and byte counts; never file bodies, stdin, stdout or stderr."
        }

        public static var missingMCPBridge: LocalizedStringResource {
            "The bundled MCP bridge is missing. Codex and Hermes setup commands are unavailable."
        }

        public static var providerCredentialUnavailable: LocalizedStringResource {
            "The provider's credential is unavailable."
        }

        public static var mcpServerAccessExplanation: LocalizedStringResource {
            "The server listens only on 127.0.0.1 and ::1. It is off by default; when enabled, external calls execute without per-call approval."
        }

        public static var mcpToolChangesExplanation: LocalizedStringResource {
            "Tool changes are enforced immediately. Existing clients see the new list when they reconnect or list tools again."
        }

        public static var mcpClientConfigurationReminder: LocalizedStringResource {
            "Update client configurations after changing the port or token, or after moving Termind for Codex and Hermes."
        }

        public static var loginItemExplanation: LocalizedStringResource {
            "macOS opens Termind when you log in, which also starts the local MCP server if you have it enabled."
        }

        public static var enterAValidProviderUrlOrAVertexProjectAndLocation: LocalizedStringResource {
            "Enter a valid provider URL, or a Vertex project and location."
        }
        public static var modelProvider: LocalizedStringResource {
            "Model Provider"
        }
        public static var unableToUpdateTheLoginItem: LocalizedStringResource {
            "Unable to update the login item."
        }
    }
}
