// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum ResourceTools {
        public static var multilineInput: LocalizedStringResource { "Multiline secret" }
        public static var secretEntered: LocalizedStringResource { "Secret entered" }
        public static var noSecretEntered: LocalizedStringResource { "No secret entered" }
        public static var secretImportFailed: LocalizedStringResource {
            "Unable to import secret. Select a nonempty UTF-8 file up to 1 MiB."
        }
        public static var addAction: LocalizedStringResource { "add" }
        public static var generateAction: LocalizedStringResource { "generate" }
        public static var startAction: LocalizedStringResource { "start" }
        public static var stopAction: LocalizedStringResource { "stop" }
        public static var refreshAction: LocalizedStringResource { "refresh" }
        public static var snippetPackages: LocalizedStringResource { "snippet packages" }
        public static var hostGroups: LocalizedStringResource { "host groups" }
        public static var startRequested: LocalizedStringResource { "Start requested" }
        public static var refreshRequested: LocalizedStringResource { "Refresh requested" }
        public static var refreshNotRequested: LocalizedStringResource { "Refresh not requested" }
    }
}
