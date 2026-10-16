import Foundation

extension AppStrings {
    public nonisolated enum LocalNetwork {
        public static var discovery: LocalizedStringResource {
            "Local Discovery"
        }
        public static var wake: LocalizedStringResource {
            "Wake"
        }
        public static var wakeOnLAN: LocalizedStringResource {
            "Wake-on-LAN"
        }
        public static var autoWake: LocalizedStringResource {
            "Auto Wake-on-LAN"
        }
        public static var macAddress: LocalizedStringResource {
            "MAC Address"
        }
        public static var fetchMAC: LocalizedStringResource {
            "Get MAC Address via SSH"
        }
        public static var invalidMAC: LocalizedStringResource {
            "Enter a valid unicast MAC address before enabling Auto Wake-on-LAN."
        }
        public static var sent: LocalizedStringResource {
            "Wake request sent. The remote machine may take a moment to become available."
        }
        public static var wakeFailed: LocalizedStringResource {
            "Could not send the wake request. Check Local Network access and your Wi-Fi or Ethernet connection."
        }
        public static var scanning: LocalizedStringResource {
            "Looking for local SSH servers…"
        }
        public static var scanningTelnet: LocalizedStringResource {
            "Looking for local Telnet servers…"
        }
        public static var rescan: LocalizedStringResource {
            "Rescan"
        }
        public static var noServers: LocalizedStringResource {
            "No SSH servers found. Enable Remote Login or an SSH server on the other device, then scan again."
        }
        public static var noTelnetServers: LocalizedStringResource {
            "No Telnet servers found. Enable a Telnet server on the other device, then scan again."
        }
        public static var unavailable: LocalizedStringResource {
            "Connect to a Wi-Fi or Ethernet network to discover local servers."
        }
        public static var permissionDenied: LocalizedStringResource {
            "Local Network access is denied. Allow Termind to access your local network in System Settings."
        }
        public static var scanFailed: LocalizedStringResource {
            "Local discovery failed. Check your network and try again."
        }
        public static var bonjour: LocalizedStringResource {
            "Bonjour"
        }
        public static var verifiedSSH: LocalizedStringResource {
            "SSH Verified"
        }
        public static var telnetPortOpen: LocalizedStringResource {
            "Port 23 Open"
        }
        public static var advertisedSSH: LocalizedStringResource {
            "SSH Advertised"
        }
        public static var noMAC: LocalizedStringResource {
            "No physical network adapter was found. Enter the MAC address manually."
        }
        public static var selectAdapter: LocalizedStringResource {
            "Choose the network adapter to wake."
        }
        public static var temporaryAuthentication: LocalizedStringResource {
            "Authentication and host-key approval are used only for this lookup. The host draft is not saved."
        }
    }
}
