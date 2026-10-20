// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

extension AppStrings.SessionPersistence {
    public static func details(windows: Int, clients: Int, locale: Locale) -> String {
        let windows = AppLocalization.resolve(Self.windows(windows), locale: locale)
        let clients = AppLocalization.resolve(Self.clients(clients), locale: locale)
        return AppLocalization.resolve(counts(windows: windows, clients: clients), locale: locale)
    }
}

extension AppStrings.Vault {
    public static func groupDeletionMessage(
        hostCount: Int, nestedGroupCount: Int, locale: Locale
    ) -> String {
        let hosts = AppLocalization.resolve(Self.hostCount(hostCount), locale: locale)
        guard nestedGroupCount != 0 else {
            return AppLocalization.resolve(groupContainsHosts(hosts), locale: locale)
        }
        let groups = AppLocalization.resolve(
            nestedGroupCount == 1 ? oneNestedGroup : Self.nestedGroupCount(nestedGroupCount), locale: locale)
        return AppLocalization.resolve(groupContainsHostsAndGroups(hosts: hosts, groups: groups), locale: locale)
    }
}

extension AppStrings.Snippets {
    public static func packageDeletionMessage(snippetCount: Int) -> LocalizedStringResource {
        snippetCount == 1 ? packageContainsOneSnippet : packageContainsSnippets(snippetCount)
    }

    public static func targetSummary(count: Int) -> LocalizedStringResource {
        switch count {
        case 0: noTargets
        case 1: oneTarget
        default: targetCount(count)
        }
    }
}

extension AppStrings.Assistant {
    public static func modelSummary(modelName: String?, effortName: String?, locale: Locale) -> String {
        guard let modelName else { return AppLocalization.resolve(noModel, locale: locale) }
        // Both values are display names. The separator is typography, not a
        // translation key; never look up user/provider model names in the catalog.
        return [modelName, effortName].compactMap { $0 }.joined(separator: " · ")
    }

    public static func modelHelp(
        modelName: String?, providerName: String?, effortName: String?
    ) -> LocalizedStringResource {
        guard let modelName, let providerName else { return noModelConfigured }
        guard let effortName else { return through(label: modelName, name: providerName) }
        return throughEffort(label: modelName, name: providerName, displayName: effortName)
    }

    public static func modelAccessibilityLabel(
        modelName: String?, effortName: String?
    ) -> LocalizedStringResource {
        guard let modelName else { return noModelAccessibilityLabel }
        guard let effortName else { return modelAccessibilityLabel(modelName) }
        return modelAndEffortAccessibilityLabel(name: modelName, effort: effortName)
    }
}

extension AppStrings.SFTP {
    public static func deletionMessage(paths: String, remainingCount: Int, locale: Locale) -> String {
        let remainder =
            remainingCount > 0
            ? AppLocalization.resolve(remainingDeletionItems(remainingCount), locale: locale) : ""
        return AppLocalization.resolve(deletionWarning(paths: paths, remainder: remainder), locale: locale)
    }

    public static func existingItemsMessage(count: Int) -> LocalizedStringResource {
        count == 1 ? oneExistingItem : existingItemCount(count)
    }
}
