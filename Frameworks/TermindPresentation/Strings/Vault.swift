// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum Vault {
        public static var icon: LocalizedStringResource { "Icon" }
        public static var unknownIcon: LocalizedStringResource { "Unknown Icon" }
        public static var addHost: LocalizedStringResource { "Add Host" }

        public static var acceptTheseImportWarnings: LocalizedStringResource {
            "Accept these import warnings"
        }

        public static var addAHostToConnectToIt: LocalizedStringResource {
            "Add a host to connect to it."
        }

        public static var addAHostToConnectWithSshOrSftp: LocalizedStringResource {
            "Add a host to connect with SSH or SFTP."
        }

        public static var allSelected: LocalizedStringResource {
            "All selected"
        }

        public static var alreadyImported: LocalizedStringResource {
            "Already imported"
        }

        public static var authentication: LocalizedStringResource {
            "Authentication"
        }

        public static var authorizeFile: LocalizedStringResource {
            "Authorize File"
        }

        public static var baudRate: LocalizedStringResource {
            "Baud Rate"
        }

        public static var charset: LocalizedStringResource {
            "Charset"
        }

        public static var clearFilter: LocalizedStringResource {
            "Clear Filter"
        }

        public static var closeAll: LocalizedStringResource {
            "Close All"
        }

        public static var color: LocalizedStringResource {
            "Color"
        }

        public static var communication: LocalizedStringResource {
            "Communication"
        }

        public static var connectionProtocol: LocalizedStringResource {
            "Connection Protocol"
        }

        public static var connectionProtocolLabel: LocalizedStringResource {
            "Connection protocol"
        }

        public static var copyAnOpenSSHCommandForThisRoute: LocalizedStringResource {
            "Copy an OpenSSH command for this route."
        }

        public static var copyTelnetCommand: LocalizedStringResource {
            "Copy Telnet Command"
        }

        public static var custom: LocalizedStringResource {
            "Custom"
        }

        public static var dataBits: LocalizedStringResource {
            "Data Bits"
        }

        public static var deleteGroupAndHosts: LocalizedStringResource {
            "Delete Group and Hosts"
        }

        public static var deleteHostConfirmation: LocalizedStringResource {
            "Delete Host?"
        }

        public static var deleteHostWarning: LocalizedStringResource {
            "Open connections and references to this host will be removed."
        }

        public static var deleteHostsConfirmation: LocalizedStringResource {
            "Delete Hosts?"
        }

        public static var device: LocalizedStringResource {
            "Device"
        }

        public static var devicePath: LocalizedStringResource {
            "Device Path"
        }

        public static var dropAKnownHostsFileHereOrChooseAFile: LocalizedStringResource {
            "Drop a known_hosts file here, or choose a file."
        }

        public static var dropASshFolderHereOrChooseAFolder: LocalizedStringResource {
            "Drop a .ssh folder here, or choose a folder."
        }

        public static func duplicatedHostName(_ name: String) -> LocalizedStringResource {
            "\(name) copy"
        }

        public static var editEnvironmentVariable: LocalizedStringResource {
            "Edit Environment Variable"
        }

        public static var editGroup: LocalizedStringResource {
            "Edit Group"
        }

        public static var editHost: LocalizedStringResource {
            "Edit Host"
        }

        public static var enterSends: LocalizedStringResource {
            "Enter Sends"
        }

        public static var filterByTag: LocalizedStringResource {
            "Filter by Tag"
        }

        public static var flowControl: LocalizedStringResource {
            "Flow Control"
        }

        public static var group: LocalizedStringResource {
            "Group"
        }

        public static func groupContainsHosts(_ hosts: String) -> LocalizedStringResource {
            "This group contains \(hosts)."
        }

        public static func groupContainsHostsAndGroups(hosts: String, groups: String) -> LocalizedStringResource {
            "This group contains \(hosts) and \(groups). Nested groups will be deleted."
        }

        public static func hostCount(_ count: Int) -> LocalizedStringResource {
            "\(count) hosts"
        }

        public static var identity: LocalizedStringResource {
            "Identity"
        }

        public static var importComplete: LocalizedStringResource {
            "Import Complete"
        }

        public static func importedItems(_ importedCount: Int) -> LocalizedStringResource {
            "Imported \(importedCount) items."
        }

        public static var jumpHost: LocalizedStringResource {
            "Jump Host"
        }

        public static var keepHosts: LocalizedStringResource {
            "Keep Hosts"
        }

        public static var key: LocalizedStringResource {
            "Key"
        }

        public static var knownHostsFile: LocalizedStringResource {
            "Known Hosts File"
        }

        public static var localEcho: LocalizedStringResource {
            "Local Echo"
        }

        public static var maxConnections: LocalizedStringResource {
            "Max Connections"
        }

        public static func nestedGroupCount(_ count: Int) -> LocalizedStringResource {
            "\(count) nested groups"
        }

        public static var never: LocalizedStringResource {
            "Never"
        }

        public static var newEnvironmentVariable: LocalizedStringResource {
            "New Environment Variable"
        }

        public static var newGroup: LocalizedStringResource {
            "New Group"
        }

        public static var newHost: LocalizedStringResource {
            "New Host"
        }

        public static var newSubgroup: LocalizedStringResource {
            "New Subgroup"
        }

        public static var noHostsHaveAllSelectedTags: LocalizedStringResource {
            "No hosts have all selected tags."
        }

        public static var noKey: LocalizedStringResource {
            "No Key"
        }

        public static var noMatchingHosts: LocalizedStringResource {
            "No Matching Hosts"
        }

        public static var noneSelected: LocalizedStringResource {
            "None selected"
        }

        public static var oneNestedGroup: LocalizedStringResource {
            "1 nested group"
        }

        public static var openWorkspace: LocalizedStringResource {
            "Open Workspace"
        }

        public static var parity: LocalizedStringResource {
            "Parity"
        }

        public static var partiallySelected: LocalizedStringResource {
            "Partially selected"
        }

        public static var password: LocalizedStringResource {
            "Password"
        }

        public static var proxy: LocalizedStringResource {
            "Proxy"
        }

        public static var proxyHostname: LocalizedStringResource {
            "Proxy Hostname"
        }

        public static var proxyIdentity: LocalizedStringResource {
            "Proxy Identity"
        }

        public static var proxyPort: LocalizedStringResource {
            "Proxy Port"
        }

        public static var proxyUsername: LocalizedStringResource {
            "Proxy Username"
        }

        public static var quickConnect: LocalizedStringResource {
            "Quick Connect"
        }

        public static var required: LocalizedStringResource {
            "Required"
        }

        public static var route: LocalizedStringResource {
            "Route"
        }

        public static var routing: LocalizedStringResource {
            "Routing"
        }

        public static var saveChangesConfirmation: LocalizedStringResource {
            "Save Changes?"
        }

        public static var saveChangesMessage: LocalizedStringResource {
            "You have unsaved changes. Save them before leaving, or discard them."
        }

        public static var serial: LocalizedStringResource {
            "Serial"
        }

        public static var session: LocalizedStringResource {
            "Session"
        }

        public static var sshCommandsAreUnavailableForRoutesThatUseAProxy: LocalizedStringResource {
            "SSH commands are unavailable for routes that use a Proxy."
        }

        public static var sshFolder: LocalizedStringResource {
            ".ssh Folder"
        }

        public static var stopBits: LocalizedStringResource {
            "Stop Bits"
        }

        public static var tags: LocalizedStringResource {
            "Tags"
        }

        public static var telnet: LocalizedStringResource {
            "Telnet"
        }

        public static var telnetCommand: LocalizedStringResource {
            "Telnet Command"
        }

        public static var theDevicePathDoesNotExist: LocalizedStringResource {
            "The device path does not exist."
        }

        public static var theDevicePathIsNotACharacterDevice: LocalizedStringResource {
            "The device path is not a character device."
        }

        public static var unlockKey: LocalizedStringResource {
            "Unlock Key"
        }

        public static var username: LocalizedStringResource {
            "Username"
        }

        public static var variable: LocalizedStringResource {
            "Variable"
        }

        public static var withSftp: LocalizedStringResource {
            "with SFTP"
        }

        public static var withSsh: LocalizedStringResource {
            "with SSH"
        }

        public static var withTelnet: LocalizedStringResource {
            "with Telnet"
        }

        public static var addATagProgress: LocalizedStringResource {
            "Add a tag…"
        }

        public static func createNamed(_ name: String) -> LocalizedStringResource {
            "Create “\(name)”"
        }

        public static var hideTagSuggestions: LocalizedStringResource {
            "Hide tag suggestions"
        }

        public static func removeTag(_ tag: String) -> LocalizedStringResource {
            "Remove tag \(tag)"
        }

        public static var showTagSuggestions: LocalizedStringResource {
            "Show tag suggestions"
        }

        public static var forwardingPoolExplanation: LocalizedStringResource {
            "Local and dynamic forwards share this connection pool. Changes apply after restart."
        }

        public static var noSerialDevicesExplanation: LocalizedStringResource {
            "No detected serial devices. You can still enter any absolute device path."
        }

        public static var deleteHostsWarning: LocalizedStringResource {
            "Open connections and references to the selected hosts will be removed."
        }

        public static var unsupportedProxyCommand: LocalizedStringResource {
            "OpenSSH commands are unavailable for routes using an HTTP or SOCKS5 proxy."
        }

        public static var emptyHostsExplanation: LocalizedStringResource {
            "Save a host here, or enter ssh user@host on the Welcome page to connect once."
        }

        public static var host: LocalizedStringResource {
            "Host"
        }
        public static var hostname: LocalizedStringResource {
            "Hostname"
        }
        public static var hosts: LocalizedStringResource {
            "Hosts"
        }
        public static var copySshCommand: LocalizedStringResource {
            "Copy SSH Command"
        }
        public static var noHosts: LocalizedStringResource {
            "No Hosts"
        }
        public static var searchHosts: LocalizedStringResource {
            "Search hosts"
        }
        public static var theHostCouldNotBeSaved: LocalizedStringResource {
            "The host could not be saved."
        }
        public static var batchStartup: LocalizedStringResource {
            "Batch Startup"
        }
        public static var ssh: LocalizedStringResource {
            "SSH"
        }
        public static var sshCommand: LocalizedStringResource {
            "SSH Command"
        }
        public static var importSshFolder: LocalizedStringResource {
            "Import .ssh Folder"
        }
    }
}
