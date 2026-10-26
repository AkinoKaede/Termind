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
        profile.approvalItems = { card, names, locale in
            ResourceToolCardPresentation.approval(card, names: names, locale: locale)
        }
        profile.detail = { card, _, locale in
            guard let content = ResourceToolCardPresentation.content(for: card, locale: locale) else { return .hidden }
            return .content(content.detail)
        }
        profile.summary = { card, locale in
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
        return profile
    }
}
