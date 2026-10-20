// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum Snippets {
        public static var unpackaged: LocalizedStringResource { "Unpackaged" }

        public static var readOnlyRisk: LocalizedStringResource { "Read-only" }
        public static var cautionRisk: LocalizedStringResource { "Caution" }
        public static var destructiveRisk: LocalizedStringResource { "Destructive" }

        public static var addAHostBeforeChoosingDefaultTargets: LocalizedStringResource {
            "Add a host before choosing default targets."
        }

        public static var deletePackageAndSnippets: LocalizedStringResource {
            "Delete Package and Snippets"
        }

        public static var deleteSnippet: LocalizedStringResource {
            "Delete Snippet"
        }

        public static var deleteSnippetConfirmation: LocalizedStringResource {
            "Delete Snippet?"
        }

        public static func deleteSnippetsConfirmation(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Snippets?"
        }

        public static var editPackage: LocalizedStringResource {
            "Edit Package"
        }

        public static var editSnippet: LocalizedStringResource {
            "Edit Snippet"
        }

        public static var emptyDescription: LocalizedStringResource {
            "Save a script and optionally choose its default hosts."
        }

        public static var keepSnippets: LocalizedStringResource {
            "Keep Snippets"
        }

        public static var newPackage: LocalizedStringResource {
            "New Package"
        }

        public static var newSnippet: LocalizedStringResource {
            "New Snippet"
        }

        public static var newSubpackage: LocalizedStringResource {
            "New Subpackage"
        }

        public static var noSavedHosts: LocalizedStringResource {
            "No saved hosts"
        }

        public static var noSnippets: LocalizedStringResource {
            "No Snippets"
        }

        public static var noTargets: LocalizedStringResource {
            "No targets"
        }

        public static var noTargetsSelected: LocalizedStringResource {
            "No targets selected"
        }

        public static var oneTarget: LocalizedStringResource {
            "1 target"
        }

        public static var package: LocalizedStringResource {
            "Package"
        }

        public static var packageContainsOneSnippet: LocalizedStringResource {
            "This package contains 1 snippet."
        }

        public static func packageContainsSnippets(_ count: Int) -> LocalizedStringResource {
            "This package tree contains \(count) snippets."
        }

        public static var risk: LocalizedStringResource {
            "Risk"
        }

        public static var runDestructiveScriptsConfirmation: LocalizedStringResource {
            "Run destructive scripts?"
        }

        public static var script: LocalizedStringResource {
            "Script"
        }

        public static func targetCount(_ count: Int) -> LocalizedStringResource {
            "\(count) targets"
        }

        public static var targets: LocalizedStringResource {
            "Targets"
        }

        public static var thisActionCannotBeUndone: LocalizedStringResource {
            "This action cannot be undone."
        }

        public static var runADestructiveScriptConfirmation: LocalizedStringResource {
            "Run a destructive script?"
        }

        public static var runOn1Host: LocalizedStringResource {
            "Run on 1 Host"
        }

        public static func runOnHosts(_ count: Int) -> LocalizedStringResource {
            "Run on \(count) Hosts"
        }

        public static var saveAsSnippet: LocalizedStringResource {
            "Save as Snippet"
        }

        public static var searchSnippets: LocalizedStringResource {
            "Search Snippets"
        }

        public static var snippetName: LocalizedStringResource {
            "Snippet Name"
        }

    }
}
