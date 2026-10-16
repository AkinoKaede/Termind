import Foundation

extension AppStrings {
    public nonisolated enum Transports {
        public static var mosh: LocalizedStringResource { "Mosh" }
        public static var eternalTerminal: LocalizedStringResource { "Eternal Terminal" }
        public static var withMosh: LocalizedStringResource { "with Mosh" }
        public static var withEternalTerminal: LocalizedStringResource { "with Eternal Terminal" }
        public static var section: LocalizedStringResource { "Transport" }
        public static var defaultTransport: LocalizedStringResource { "Default" }
        public static var portRange: LocalizedStringResource { "Port Range" }
        public static var retryNow: LocalizedStringResource { "Retry Now" }
        public static var closeSession: LocalizedStringResource { "Close Session" }
        public static var sessionUnavailable: LocalizedStringResource {
            "The terminal session cannot continue. Open a new session to connect again."
        }
    }
}
