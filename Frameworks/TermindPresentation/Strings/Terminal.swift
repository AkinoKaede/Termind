// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum Terminal {
        public static var uploadFile: LocalizedStringResource { "Upload File" }

        public static var connectionLog: LocalizedStringResource {
            "Connection Log"
        }

        public static var noDetectedSerialDevices: LocalizedStringResource {
            "No detected serial devices"
        }

        public static var reconnect: LocalizedStringResource {
            "Reconnect"
        }

        public static func rejectedEnvironmentVariables(_ names: String) -> LocalizedStringResource {
            "The server rejected these environment variables: \(names)"
        }

        public static func sshConnectionFailedWhatShouldICheckConfirmation(_ message: String) -> LocalizedStringResource
        {
            "SSH connection failed: \(message). What should I check?"
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

        public static var commandsConfirmedByTheRemoteShellAppearHere: LocalizedStringResource {
            "Shell history and commands from this session appear here."
        }
        public static var copyLogs: LocalizedStringResource {
            "Copy Logs"
        }
    }
}
