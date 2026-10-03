import Foundation

extension AppStrings {
    public nonisolated enum Tailscale {
        public static var ping: LocalizedStringResource { "Ping" }
        public static var stopPing: LocalizedStringResource { "Stop Ping" }
        public static var status: LocalizedStringResource { "Status" }
        public static var online: LocalizedStringResource { "Online" }
        public static var offline: LocalizedStringResource { "Offline" }
        public static var lastSeen: LocalizedStringResource { "Last Seen" }
        public static var latency: LocalizedStringResource { "Latency" }
        public static var route: LocalizedStringResource { "Route" }
        public static var direct: LocalizedStringResource { "Direct" }
        public static var peerRelay: LocalizedStringResource { "Peer Relay" }
        public static var unknownRoute: LocalizedStringResource { "Unknown Route" }
        public static var endpoint: LocalizedStringResource { "Endpoint" }
        public static var derpRegion: LocalizedStringResource { "DERP region" }
        public static var noPingData: LocalizedStringResource { "No data" }
        public static var directConnection: LocalizedStringResource { "Direct connection" }
        public static var peerRelayConnection: LocalizedStringResource { "Peer relay connection" }
        public static var derpConnection: LocalizedStringResource { "DERP-relayed connection" }
        public static var exitNode: LocalizedStringResource { "Exit Node" }
        public static var selectedExitNodeUnavailable: LocalizedStringResource { "Selected exit node is unavailable" }
        public static func sftpFailure(username: String, address: String, detail: String) -> LocalizedStringResource {
            "SFTP connection to \(username)@\(address) failed: \(detail)"
        }
        public static var title: LocalizedStringResource { "Tailscale" }
        public static var login: LocalizedStringResource { "Login" }
        public static var interactive: LocalizedStringResource { "Interactive Login" }
        public static var authKey: LocalizedStringResource { "Auth Key" }
        public static var controlURL: LocalizedStringResource { "Controlplane URL" }
        public static var openLogin: LocalizedStringResource { "Open login page" }
        public static var networkName: LocalizedStringResource { "Network" }
        public static var magicDNS: LocalizedStringResource { "MagicDNS" }
        public static var ipv4: LocalizedStringResource { "IPv4" }
        public static var ipv6: LocalizedStringResource { "IPv6" }
        public static var keyExpiry: LocalizedStringResource { "Key Expiry" }
        public static var operatingSystem: LocalizedStringResource { "OS" }
        public static var logout: LocalizedStringResource { "Log out" }
        public static var check: LocalizedStringResource { "Tailscale SSH approval" }
        public static var network: LocalizedStringResource { "Tailnet" }
        public static var signedOut: LocalizedStringResource { "Sign in on this device to use this Tailnet." }
        public static var unavailable: LocalizedStringResource {
            "This Tailscale connection is unavailable. Check the Tailnet login, SSH policy, and username."
        }
        public static var invalidURL: LocalizedStringResource { "Enter a valid HTTPS Controlplane URL." }
        public static var partialSave: LocalizedStringResource {
            "The group was saved, but this device could not finish signing in. Save again to retry."
        }
        public static var requiresPro: LocalizedStringResource { "Tailscale requires Termind Pro." }
    }
}
