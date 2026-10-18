import Foundation

extension AppStrings {
    public nonisolated enum SessionPersistence {
        public static var section: LocalizedStringResource { "Session Persistence" }
        public static var backend: LocalizedStringResource { "Backend" }
        public static var onConnect: LocalizedStringResource { "On Connect" }
        public static var ask: LocalizedStringResource { "Ask Every Time" }
        public static var normalShell: LocalizedStringResource { "Use a Normal Shell" }
        public static var title: LocalizedStringResource { "Choose a Remote Session" }
        public static var create: LocalizedStringResource { "New Managed Session" }
        public static var empty: LocalizedStringResource { "No remote sessions are running." }
        public static var missing: LocalizedStringResource { "The session backend is not installed on this host." }
        public static var unsupported: LocalizedStringResource {
            "This session backend or reference version is not supported."
        }
        public static var timedOut: LocalizedStringResource { "Preparing the remote session timed out." }
        public static var failed: LocalizedStringResource { "Unable to prepare the remote session." }
        public static var startupUnavailable: LocalizedStringResource {
            "The startup command could not run in the session shell. Check the shell and backend configuration."
        }
        public static var changed: LocalizedStringResource {
            "The saved remote session is missing or its identity changed."
        }
        public static var detached: LocalizedStringResource {
            "Detached from the remote session. Reconnect to attach again."
        }
        public static var ended: LocalizedStringResource { "The remote session has ended." }
        public static func counts(windows: String, clients: String) -> LocalizedStringResource {
            "\(windows), \(clients)"
        }
        public static func windows(_ count: Int) -> LocalizedStringResource { "\(count) windows" }
        public static func clients(_ count: Int) -> LocalizedStringResource { "\(count) connected clients" }
    }
}
