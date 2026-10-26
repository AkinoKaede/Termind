// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

nonisolated enum ResourceToolPresentation {
    static var profile: AgentToolPresentationProfile {
        var profile = AgentToolPresentationProfile()
        profile.requiresArgumentProjection = true
        profile.usesSummaryForSingleCompletedBatch = true
        profile.activity = { card, locale in
            activity(for: card, plural: card.descriptor.presentation?.actionKind == .list, locale: locale)
        }
        profile.batchOperation = { cards, locale in
            guard let first = cards.first, let action = first.descriptor.presentation?.actionKind,
                let activity = activity(
                    for: first, plural: cards.count > 1 || action == .list, locale: locale)
            else { return nil }
            return .init(
                action: action,
                activity: cards.count == 1
                    ? activity
                    : AppLocalization.resolve(
                        AppStrings.ResourceTools.repeated(activity, count: cards.count), locale: locale))
        }
        profile.approvalItems = { card, names, locale in
            ResourceToolCardPresentation.approval(card, names: names, locale: locale)
        }
        profile.detail = { card, _, locale in
            guard let content = ResourceToolCardPresentation.content(for: card, locale: locale) else { return .hidden }
            return .content(content.detail)
        }
        profile.summary = requestSummary
        profile.batchSummary = { cards, locale in
            let summaries = cards.compactMap { requestSummary($0, locale: locale) }
            guard !summaries.isEmpty, summaries.count == cards.count else { return nil }
            var order: [String] = []
            var counts: [String: Int] = [:]
            for summary in summaries {
                if counts[summary] == nil { order.append(summary) }
                counts[summary, default: 0] += 1
            }
            return AgentToolPresentation.joinedBatchClauses(
                order.map { summary in
                    let count = counts[summary, default: 0]
                    return count == 1
                        ? summary
                        : AppLocalization.resolve(
                            AppStrings.ResourceTools.repeated(summary, count: count), locale: locale)
                }, locale: locale)
        }
        return profile
    }

    private static func activity(for card: AgentToolCard, plural: Bool, locale: Locale) -> String? {
        guard let resource = ResourceToolCardPresentation.resource(card.descriptor.name) else { return nil }
        typealias S = AppStrings.ResourceTools
        let copy: LocalizedStringResource
        switch resource {
        case .host: copy = plural ? S.hosts : S.host
        case .hostGroup: copy = plural ? S.hostGroups : S.hostGroup
        case .identity: copy = plural ? S.identities : S.identity
        case .key: copy = plural ? S.keys : S.key
        case .snippet: copy = plural ? S.snippets : S.snippet
        case .package: copy = plural ? S.snippetPackages : S.snippetPackage
        case .forwarding: copy = plural ? S.forwardingRules : S.forwardingRule
        case .metrics:
            copy =
                card.descriptor.name == TermindToolName.getMetrics
                ? S.hostMetrics : plural ? S.metricsMonitors : S.metricsMonitor
        }
        return AppLocalization.resolve(copy, locale: locale)
    }

    private static func requestSummary(_ card: AgentToolCard, locale: Locale) -> String? {
        guard card.state == .completed, card.result?.isError != true else { return nil }
        switch card.descriptor.name {
        case TermindToolName.startMetrics, TermindToolName.startPortForwarding:
            return AppLocalization.resolve(AppStrings.ResourceTools.startRequested, locale: locale)
        case TermindToolName.refreshMetrics:
            let raw = card.result?.untrustedPayload ?? card.result?.content ?? ""
            let result = try? AgentJSONValue.decode(Data(raw.utf8))
            let requested = result?.objectValue?["refresh_requested"]?.boolValue == true
            return AppLocalization.resolve(
                requested
                    ? AppStrings.ResourceTools.refreshRequested : AppStrings.ResourceTools.refreshNotRequested,
                locale: locale)
        default: return nil
        }
    }
}
