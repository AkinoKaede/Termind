import Foundation

extension AppStrings {
    public nonisolated enum MCP {
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
