// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum ResourceCards {
        public static var resource: LocalizedStringResource { "Resource" }
        public static var none: LocalizedStringResource { "None" }
        public static var unknown: LocalizedStringResource { "Unknown" }
        public static var yes: LocalizedStringResource { "Yes" }
        public static var no: LocalizedStringResource { "No" }
        public static var empty: LocalizedStringResource { "No resources found" }
        public static var deleted: LocalizedStringResource { "Resource deleted" }
        public static var unavailable: LocalizedStringResource { "Resource details are unavailable." }
        public static var newCredential: LocalizedStringResource { "New credential provided" }
        public static var provided: LocalizedStringResource { "Provided" }
        public static var clear: LocalizedStringResource { "Clear" }
        public static var noChanges: LocalizedStringResource { "No configuration changes" }
        public static var keepContents: LocalizedStringResource {
            "Keep contents and move them out of the deleted group."
        }
        public static var deleteContents: LocalizedStringResource {
            "Delete this group, its descendants, and their contents."
        }
        public static var authenticationRequired: LocalizedStringResource {
            "Complete authentication or host verification in Termind."
        }
        public static var stale: LocalizedStringResource { "Cached metrics are stale" }
        public static var denied: LocalizedStringResource { "This operation was not approved." }
        public static var cancelled: LocalizedStringResource { "Cancelled" }
        public static var failed: LocalizedStringResource {
            "The resource operation failed. Check the configuration and try again."
        }
        public static var allDevices: LocalizedStringResource { "All devices" }
        public static var noDevices: LocalizedStringResource { "No devices selected" }
        public static func resourceCount(_ count: Int) -> LocalizedStringResource {
            "\(count) resources"
        }
        public static func lineCount(_ count: Int) -> LocalizedStringResource {
            "\(count) lines"
        }
        public static func targetCount(_ count: Int) -> LocalizedStringResource {
            "\(count) targets"
        }
        public static func deviceCount(_ count: Int) -> LocalizedStringResource {
            "\(count) devices"
        }
        static let failures: [String: LocalizedStringResource] = [
            "The requested resource does not exist.": "The requested resource does not exist.",
            "Invalid resource configuration or conflicting fields.":
                "Invalid resource configuration or conflicting fields.",
            "A referenced resource is unavailable.": "A referenced resource is unavailable.",
            "This operation is not supported for this resource.": "This operation is not supported for this resource.",
            "The resource could not be saved.": "The resource could not be saved.",
            "Credential operation failed. Check the input and device availability, then request new handles.":
                "Unable to save credentials. Check the input and device, then provide the credentials again.",
        ]
        static let labels: [String: LocalizedStringResource] = [
            "host_id": "Host",
            "host_group_id": "Host Group",
            "identity_id": "Identity",
            "key_id": "Key",
            "port_forwarding_id": "Port Forwarding",
            "snippet_id": "Snippet",
            "snippet_package_id": "Snippet Package",
            "name": "Name",
            "label": "Name",
            "title": "Title",
            "username": "Username",
            "address": "Address",
            "group_id": "Group",
            "parent_id": "Parent Group",
            "storage": "Storage",
            "algorithm": "Algorithm",
            "bits": "Key Size",
            "availability": "Availability",
            "fingerprint": "Fingerprint",
            "encrypted": "Encrypted",
            "requires_user_presence": "Require User Presence",
            "public_key": "Public Key",
            "certificate": "Certificate",
            "notes": "Notes",
            "body": "Script",
            "package_id": "Snippet Package",
            "target_host_ids": "Target Hosts",
            "enabled": "Enabled",
            "status": "Status",
            "disks": "Disks",
            "interfaces": "Network Interfaces",
            "cpu_percent": "CPU",
            "memory_percent": "Memory",
            "swap_percent": "Swap",
            "sampled_at": "Sampled at",
            "kind": "Type",
            "listener": "Listener",
            "socks_listener": "SOCKS Listener",
            "destination": "Destination",
            "bind_host": "Bind Address",
            "bind_port": "Bind Port",
            "target_host": "Target Host",
            "target_port": "Target Port",
            "protocols": "Protocols",
            "ssh_enabled": "SSH",
            "telnet_enabled": "Telnet",
            "ssh_port": "SSH Port",
            "telnet_port": "Telnet Port",
            "ssh_identity_id": "SSH Identity",
            "telnet_identity_id": "Telnet Identity",
            "jump_host_id": "Jump Host",
            "proxy": "Proxy",
            "telnet_proxy": "Telnet Proxy",
            "startup_snippet_id": "Startup Snippet",
            "password_secret_handle": "Password",
            "private_key_secret_handle": "Private Key",
            "passphrase_secret_handle": "Passphrase",
            "password": "Password",
            "passphrase": "Passphrase",
            "save_passphrase": "Save Passphrase",
            "color": "Color",
            "tags": "Tags",
            "ssh_charset": "SSH Character Encoding",
            "telnet_charset": "Telnet Character Encoding",
            "sftp_initial_path": "Initial Path",
            "icon_override_id": "Icon",
            "shell_integration": "Shell Integration",
            "agent_forwarding_enabled": "Agent Forwarding",
            "forwarding_max_connections": "Maximum Connections",
            "environment_variables": "Environment Variables",
            "mosh_enabled": "Mosh",
            "mosh_udp_port_range": "UDP Port Range",
            "eternal_terminal_enabled": "Eternal Terminal",
            "eternal_terminal_port": "Eternal Terminal Port",
            "default_transport": "Default Transport",
            "session_persistence_enabled": "Session Persistence",
            "session_backend": "Backend",
            "session_on_connect": "On Connect",
            "wake_mac_address": "MAC Address",
            "automatically_wake": "Wake Automatically",
        ]
        static let states: [String: LocalizedStringResource] = [
            "available": "Available",
            "missing": "Missing",
            "unavailable": "Unavailable",
            "not_configured": "Not Configured",
            "thisDevice": "This Device",
            "iCloud": "iCloud",
            "secureEnclave": "Secure Enclave",
            "securityKey": "Security Key",
            "external": "Security Key",
            "local": "Local",
            "remote": "Remote",
            "dynamic": "Dynamic",
            "running": "Running",
            "stopped": "Stopped",
            "live": "Live",
            "paused": "Paused",
            "sleeping": "Sleeping",
            "connecting": "Connecting…",
            "reconnecting": "Reconnecting…",
            "preparing": "Preparing…",
            "starting": "Starting…",
            "collecting": "Connected — collecting metrics…",
            "awaiting_authentication": "Authentication required",
            "awaiting_trust": "Host verification required",
            "failed": "Failed",
            "not_monitored": "Not monitored",
            "connected": "Connected",
            "disconnected": "Disconnected",
        ]
        static let argumentOrder = [
            "host_id",
            "host_group_id",
            "identity_id",
            "key_id",
            "port_forwarding_id",
            "snippet_id",
            "snippet_package_id",
            "name",
            "label",
            "title",
            "username",
            "address",
            "group_id",
            "parent_id",
            "storage",
            "algorithm",
            "bits",
            "requires_user_presence",
            "public_key",
            "certificate",
            "notes",
            "body",
            "package_id",
            "target_host_ids",
            "enabled",
            "disks",
            "interfaces",
            "kind",
            "bind_host",
            "bind_port",
            "target_host",
            "target_port",
            "ssh_enabled",
            "telnet_enabled",
            "ssh_port",
            "telnet_port",
            "ssh_identity_id",
            "telnet_identity_id",
            "jump_host_id",
            "proxy",
            "telnet_proxy",
            "startup_snippet_id",
            "password_secret_handle",
            "private_key_secret_handle",
            "passphrase_secret_handle",
            "save_passphrase",
            "color",
            "tags",
            "ssh_charset",
            "telnet_charset",
            "sftp_initial_path",
            "icon_override_id",
            "shell_integration",
            "agent_forwarding_enabled",
            "forwarding_max_connections",
            "environment_variables",
            "mosh_enabled",
            "mosh_udp_port_range",
            "eternal_terminal_enabled",
            "eternal_terminal_port",
            "default_transport",
            "session_persistence_enabled",
            "session_backend",
            "session_on_connect",
            "wake_mac_address",
            "automatically_wake",
            "clear_fields",
        ]
    }
}
