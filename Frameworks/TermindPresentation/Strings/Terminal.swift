import Foundation

extension AppStrings {
    public nonisolated enum Terminal {
        public static var uploadFile: LocalizedStringResource { "Upload File" }

        public static var armed: LocalizedStringResource {
            "Armed"
        }

        public static var charsetError: LocalizedStringResource {
            "Charset Error"
        }

        public static var clearHistoryConfirmation: LocalizedStringResource {
            "Clear History?"
        }

        public static var connectionLog: LocalizedStringResource {
            "Connection Log"
        }

        public static var control: LocalizedStringResource {
            "Control"
        }

        public static var commandKey: LocalizedStringResource {
            "Command Key"
        }

        public static var downArrow: LocalizedStringResource {
            "Down Arrow"
        }

        public static var end: LocalizedStringResource {
            "End"
        }

        public static var escape: LocalizedStringResource {
            "Escape"
        }

        public static var hideKeyboard: LocalizedStringResource {
            "Hide Keyboard"
        }

        public static var home: LocalizedStringResource {
            "Home"
        }

        public static var inactive: LocalizedStringResource {
            "Inactive"
        }

        public static var leftArrow: LocalizedStringResource {
            "Left Arrow"
        }

        public static var locked: LocalizedStringResource {
            "Locked"
        }

        public static var noDetectedSerialDevices: LocalizedStringResource {
            "No detected serial devices"
        }

        public static var option: LocalizedStringResource {
            "Option"
        }

        public static var pageDown: LocalizedStringResource {
            "Page Down"
        }

        public static var pageUp: LocalizedStringResource {
            "Page Up"
        }

        public static var reconnect: LocalizedStringResource {
            "Reconnect"
        }

        public static func rejectedEnvironmentVariables(_ names: String) -> LocalizedStringResource {
            "The server rejected these environment variables: \(names)"
        }

        public static var rightArrow: LocalizedStringResource {
            "Right Arrow"
        }

        public static var shift: LocalizedStringResource {
            "Shift"
        }

        public static var showKeyboard: LocalizedStringResource {
            "Show Keyboard"
        }

        public static func sshConnectionFailedWhatShouldICheckConfirmation(_ message: String) -> LocalizedStringResource
        {
            "SSH connection failed: \(message). What should I check?"
        }

        public static var tab: LocalizedStringResource {
            "Tab"
        }

        public static var theSavedPasswordIsNoLongerAvailable: LocalizedStringResource {
            "The saved password is no longer available."
        }

        public static var theSelectedKeyHasNoSavedPrivateKey: LocalizedStringResource {
            "The selected key has no saved private key."
        }

        public static var theSelectedKeyIsNoLongerAvailable: LocalizedStringResource {
            "The selected key is no longer available."
        }

        public static var upArrow: LocalizedStringResource {
            "Up Arrow"
        }

        public static var applySerialSettings: LocalizedStringResource {
            "Apply serial settings"
        }

        public static var closeFind: LocalizedStringResource {
            "Close Find"
        }

        public static var enterAnAbsoluteDevicePathAndAValidBaudRate: LocalizedStringResource {
            "Enter an absolute device path and a valid baud rate."
        }

        public static var findNextInTerminal: LocalizedStringResource {
            "Find Next in Terminal"
        }

        public static var findPreviousInTerminal: LocalizedStringResource {
            "Find Previous in Terminal"
        }

        public static var openSerialPort: LocalizedStringResource {
            "Open serial port"
        }

        public static var openingTheSerialPortTimedOut: LocalizedStringResource {
            "Opening the serial port timed out."
        }

        public static var readSerialPort: LocalizedStringResource {
            "Read serial port"
        }

        public static var readSerialSettings: LocalizedStringResource {
            "Read serial settings"
        }

        public static var reconnectedANewRemoteShellHasStarted: LocalizedStringResource {
            "Reconnected; a new remote shell has started."
        }

        public static var serialDeviceOpened: LocalizedStringResource {
            "Serial device opened"
        }

        public static var serialInputMonitoringStarted: LocalizedStringResource {
            "Serial input monitoring started"
        }

        public static var serialSettingsApplied: LocalizedStringResource {
            "Serial settings applied"
        }

        public static var setBaudRate: LocalizedStringResource {
            "Set baud rate"
        }

        public static var theTelnetConnectionClosed: LocalizedStringResource {
            "The Telnet connection closed."
        }

        public static var theSerialPortIsClosed: LocalizedStringResource {
            "The serial port is closed."
        }

        public static var writeSerialPort: LocalizedStringResource {
            "Write serial port"
        }

        public static var clearCommandHistoryWarning: LocalizedStringResource {
            "This permanently removes all saved commands for the current Host."
        }

        public static var commandHistoryRequirement: LocalizedStringResource {
            "This session is not recording history. Enable Shell Integration and use bash, zsh, or fish."
        }

        public static var clearCommandHistoryForThisHostConfirmation: LocalizedStringResource {
            "Clear command history for this Host?"
        }
        public static var commandsConfirmedByTheRemoteShellAppearHere: LocalizedStringResource {
            "Commands confirmed by the remote shell appear here."
        }
        public static var copyLogs: LocalizedStringResource {
            "Copy Logs"
        }
    }
}
