import Foundation

extension AppStrings {
    public nonisolated enum Connections {
        public static var authenticationCancelled: LocalizedStringResource {
            "Authentication was cancelled. Retry to continue connecting."
        }
        public static var agentForwarding: LocalizedStringResource { "Agent Forwarding" }

        public static var authenticationRequest: LocalizedStringResource {
            "Authentication Request"
        }

        public static var connecting: LocalizedStringResource {
            "Connecting"
        }

        public static var connectionFailed: LocalizedStringResource {
            "Connection Failed"
        }

        public static var connectionLostReconnectingProgress: LocalizedStringResource {
            "Connection lost; reconnecting…"
        }

        public static var enterATelnetDestination: LocalizedStringResource {
            "Enter a Telnet destination."
        }

        public static var enterAValueForL: LocalizedStringResource {
            "Enter a value for -l."
        }

        public static func enterAValueFor(_ token: String) -> LocalizedStringResource {
            "Enter a value for \(token)."
        }

        public static var enterAnSshDestination: LocalizedStringResource {
            "Enter an SSH destination."
        }

        public static var finishTheBracketedIPv6Address: LocalizedStringResource {
            "Finish the bracketed IPv6 address."
        }

        public static var finishTheQuotedOrEscapedArgument: LocalizedStringResource {
            "Finish the quoted or escaped argument."
        }

        public static var invalidSshDestination: LocalizedStringResource {
            "Invalid SSH destination."
        }

        public static var invalidSshPort: LocalizedStringResource {
            "Invalid SSH port."
        }

        public static var invalidTelnetDestination: LocalizedStringResource {
            "Invalid Telnet destination."
        }

        public static var invalidTelnetPort: LocalizedStringResource {
            "Invalid Telnet port."
        }

        public static func moreThanOneSavedHostIsNamed(_ host: String) -> LocalizedStringResource {
            "More than one saved host is named “\(host)”."
        }

        public static var reconnecting: LocalizedStringResource {
            "Reconnecting"
        }

        public static var remoteCommandsAreNotSupportedHere: LocalizedStringResource {
            "Remote commands are not supported here."
        }

        public static var shellExpressionsAreNotSupportedHere: LocalizedStringResource {
            "Shell expressions are not supported here."
        }

        public static func unsupportedSshOption(_ option: String) -> LocalizedStringResource {
            "Unsupported SSH option: \(option)."
        }

        public static func unsupportedTelnetOption(_ value: String) -> LocalizedStringResource {
            "Unsupported Telnet option: \(value)."
        }

        public static var useOneJOptionWithCommaSeparatedJumpHosts: LocalizedStringResource {
            "Use one -J option with comma-separated jump hosts."
        }

        public static func connectWithSsh(_ value: String) -> LocalizedStringResource {
            "Connect with SSH · \(value)"
        }
        public static func connectWithTelnet(_ value: String) -> LocalizedStringResource {
            "Connect with Telnet · \(value)"
        }
        public static var clearConnectionHistoryConfirmation: LocalizedStringResource {
            "Clear connection history?"
        }
        public static var hostsYouConnectToAppearHere: LocalizedStringResource {
            "Hosts you connect to appear here."
        }
        public static var openWithSsh: LocalizedStringResource {
            "Open with SSH"
        }
        public static var sshIsDisabledForThisHost: LocalizedStringResource {
            "SSH is disabled for this Host."
        }
        public static var telnetIsDisabledForThisHost: LocalizedStringResource {
            "Telnet is disabled for this Host."
        }
        public static var theHostConfigurationChangedReconnectToApplyIt: LocalizedStringResource {
            "The Host configuration changed. Reconnect to apply it."
        }
        public static var theHostIsNoLongerAvailable: LocalizedStringResource {
            "The host is no longer available."
        }
        public static var notConnected: LocalizedStringResource {
            "Not connected"
        }
        public static var connected: LocalizedStringResource {
            "Connected"
        }
        public static var disconnected: LocalizedStringResource {
            "Disconnected"
        }
    }
}
