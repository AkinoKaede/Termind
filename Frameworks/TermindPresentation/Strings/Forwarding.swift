// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum Forwarding {
        public static var address: LocalizedStringResource {
            "Address"
        }

        public static var anyActiveForwardingSessionForThisRuleWillBeStopped: LocalizedStringResource {
            "Any active forwarding session for this rule will be stopped."
        }

        public static var copyAddress: LocalizedStringResource {
            "Copy Address"
        }

        public static var createAForwardingRuleThenStartItManually: LocalizedStringResource {
            "Create a forwarding rule, then start it manually."
        }

        public static var deleteForwardingRuleConfirmation: LocalizedStringResource {
            "Delete Forwarding Rule?"
        }

        public static var deleteForwardingRulesConfirmation: LocalizedStringResource {
            "Delete Forwarding Rules?"
        }

        public static func deleteForwardingRulesConfirmationNamed(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Forwarding Rules?"
        }

        public static var direction: LocalizedStringResource {
            "Direction"
        }

        public static var editForwarding: LocalizedStringResource {
            "Edit Forwarding"
        }

        public static var hostUnavailable: LocalizedStringResource {
            "Host Unavailable"
        }

        public static var newForwarding: LocalizedStringResource {
            "New Forwarding"
        }

        public static var noPortForwarding: LocalizedStringResource {
            "No Port Forwarding"
        }

        public static var start: LocalizedStringResource {
            "Start"
        }

        public static var theForwardingRuleIsUnavailable: LocalizedStringResource {
            "The forwarding rule is unavailable."
        }

        public static var deleteActiveRulesWarning: LocalizedStringResource {
            "Any active forwarding sessions for the selected rules will be stopped."
        }

    }
}
