// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum Diagnosis {
        public static var title: LocalizedStringResource { "Diagnostics" }
        public static var invitation: LocalizedStringResource { "Help make Termind more reliable" }
        public static var explanation: LocalizedStringResource {
            "Allow Termind to send diagnostic data to Google? This includes crash details, app and operating system versions, device information, and diagnostic identifiers."
        }
        public static var privacy: LocalizedStringResource {
            "Termind does not attach terminal output, chat content, passwords, or private keys to diagnostic data."
        }
        public static var choice: LocalizedStringResource {
            "This is optional. Your choice applies to this device, and you can change it in Settings > App."
        }
        public static var decline: LocalizedStringResource { "Don't Send" }
        public static var sendDiagnosticData: LocalizedStringResource { "Send Diagnostics" }
        public static var settingsExplanation: LocalizedStringResource {
            "Send diagnostic data to Google Firebase Crashlytics to help make Termind more reliable."
        }
    }
}
