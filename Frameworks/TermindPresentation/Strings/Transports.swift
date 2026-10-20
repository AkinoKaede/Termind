// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
        public static var recoveringSession: LocalizedStringResource { "Restoring the existing terminal session" }
        public static var sessionSuspended: LocalizedStringResource {
            "The terminal session is paused. It will resume when the app returns to the foreground."
        }
        public static var sessionUnavailable: LocalizedStringResource {
            "The terminal session cannot continue. Open a new session to connect again."
        }
    }
}
