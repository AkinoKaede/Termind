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
        public static var host: LocalizedStringResource { "a host" }
        public static var hosts: LocalizedStringResource { "hosts" }
        public static var hostGroup: LocalizedStringResource { "a host group" }
        public static var identity: LocalizedStringResource { "an identity" }
        public static var identities: LocalizedStringResource { "identities" }
        public static var key: LocalizedStringResource { "a key" }
        public static var keys: LocalizedStringResource { "keys" }
        public static var snippet: LocalizedStringResource { "a snippet" }
        public static var snippets: LocalizedStringResource { "snippets" }
        public static var snippetPackage: LocalizedStringResource { "a snippet package" }
        public static var snippetPackages: LocalizedStringResource { "snippet packages" }
        public static var hostGroups: LocalizedStringResource { "host groups" }
        public static var forwardingRule: LocalizedStringResource { "a port forwarding rule" }
        public static var forwardingRules: LocalizedStringResource { "port forwarding rules" }
        public static var metricsMonitor: LocalizedStringResource { "a metrics monitor" }
        public static var metricsMonitors: LocalizedStringResource { "metrics monitors" }
        public static var hostMetrics: LocalizedStringResource { "host metrics" }
        public static var startRequested: LocalizedStringResource { "Start requested" }
        public static var refreshRequested: LocalizedStringResource { "Refresh requested" }
        public static var refreshNotRequested: LocalizedStringResource { "Refresh not requested" }

        public static func repeated(_ activity: String, count: Int) -> LocalizedStringResource {
            "\(activity) (\(count) times)"
        }
    }
}
