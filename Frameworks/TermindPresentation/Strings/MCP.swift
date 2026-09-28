import Foundation

extension AppStrings {
    public nonisolated enum MCP {
        public static var importServers: LocalizedStringResource {
            "Import Servers"
        }

        public static var importUnreadableFile: LocalizedStringResource {
            "Choose a readable MCP JSON file no larger than 1 MB."
        }

        public static var importInvalidDocument: LocalizedStringResource {
            "The JSON file must contain an mcpServers object."
        }

        public static var importInvalidEntry: LocalizedStringResource {
            "The server configuration is invalid."
        }

        public static var importUnsupportedTransport: LocalizedStringResource {
            "Only remote HTTP and SSE servers can be imported."
        }

        public static var importUnresolvedVariable: LocalizedStringResource {
            "Replace variable references with values before importing."
        }

        public static var importUnsupportedAuthentication: LocalizedStringResource {
            "This authentication configuration cannot be imported. Use a Bearer Authorization header and non-secret custom headers."
        }

        public static var importSaveFailed: LocalizedStringResource {
            "The server could not be saved."
        }

        public static var importSecretFailed: LocalizedStringResource {
            "The server credential could not be saved."
        }

        public static var importSecretCleanupFailed: LocalizedStringResource {
            "The server was not imported, and its new credential could not be removed."
        }

        public static func importedServers(_ count: Int) -> LocalizedStringResource {
            "Imported MCP servers: \(count)"
        }

        public static func importEntryProblem(_ index: Int, _ reason: String) -> LocalizedStringResource {
            "Entry \(index) skipped: \(reason)"
        }

        public static var secondsSuffix: LocalizedStringResource { "s" }

        public static var destination: LocalizedStringResource {
            "Destination"
        }

        public static var externalToolCallsAreNoLongerAuthorized: LocalizedStringResource {
            "External tool calls are no longer authorized."
        }

        public static var httpUploadsAreNotAvailable: LocalizedStringResource {
            "HTTP uploads are not available."
        }

        public static var listSavedHosts: LocalizedStringResource {
            "List saved hosts"
        }

        public static func listeningOnLocalhost(_ value: String) -> LocalizedStringResource {
            "Listening on localhost:\(value)"
        }

        public static var off: LocalizedStringResource {
            "Off"
        }

        public static var purpose: LocalizedStringResource {
            "Purpose"
        }

        public static func requestedBy(_ clientName: String) -> LocalizedStringResource {
            "Requested by \(clientName)"
        }

        public static var secretInput: LocalizedStringResource {
            "Secret input"
        }

        public static var startingProgress: LocalizedStringResource {
            "Starting…"
        }

        public static var secretHandleExplanation: LocalizedStringResource {
            "Termind returns only a one-shot handle to the MCP client. The value is bound to this session, destination, ssh_exec, and purpose."
        }

        public static var theUploadIsUnknownOrExpired: LocalizedStringResource {
            "The upload is unknown or expired."
        }

        public static var theUploadRequestIsInvalid: LocalizedStringResource {
            "The upload request is invalid."
        }

        public static var tooManyUploadsAreWaiting: LocalizedStringResource {
            "Too many uploads are waiting."
        }

        public static var unableToGenerateASecureToken: LocalizedStringResource {
            "Unable to generate a secure token."
        }

        public static var unknownMcpClient: LocalizedStringResource {
            "Unknown MCP client"
        }

        public static func unknownOrDisabledTool(_ name: String) -> LocalizedStringResource {
            "Unknown or disabled tool: \(name)"
        }

        public static var addServer: LocalizedStringResource {
            "Add Server"
        }
        public static var mcpServer: LocalizedStringResource {
            "MCP Server"
        }
        public static var invalidDownloadRequest: LocalizedStringResource { "The download request is invalid." }
        public static var downloadsUnavailable: LocalizedStringResource { "HTTP downloads are not available." }
        public static var tooManyPendingDownloads: LocalizedStringResource { "Too many downloads are waiting." }
        public static var unknownOrExpiredDownload: LocalizedStringResource { "The download is unknown or expired." }
    }
}
