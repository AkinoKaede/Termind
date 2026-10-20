// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// Localized knowledge operations supplied by the tool's registered presenter.
nonisolated enum AgentKnowledgeToolPresentation {
    static func configure(_ profile: inout AgentToolPresentationProfile, presenter: AgentToolDetailPresenter) {
        profile.operation = { card, locale, approval in
            operation(for: card, presenter: presenter, locale: locale, approval: approval)
        }
        profile.summary = { card, locale in scopedSearchSummary(for: card, presenter: presenter, locale: locale) }
        profile.title = title
    }

    private static func semantics(for card: AgentToolCard, presenter: AgentToolDetailPresenter) -> AgentToolOperation? {
        presenter.resolveOperation(arguments: card.invocation.call.arguments.objectValue ?? [:])
    }

    private static func scopedSearchSummary(
        for card: AgentToolCard, presenter: AgentToolDetailPresenter, locale: Locale
    ) -> String? {
        guard card.state == .running || card.state == .completed,
            let operation = semantics(for: card, presenter: presenter), let query = operation.argument,
            let scope = operation.searchScope
        else { return nil }
        let scopeName = activity(scope, locale: locale)
        func rendered(_ query: String) -> String {
            switch card.state {
            case .running:
                AppLocalization.resolve(AppStrings.Assistant.searching(query, in: scopeName), locale: locale)
            default:
                AppLocalization.resolve(AppStrings.Assistant.searched(query, in: scopeName), locale: locale)
            }
        }
        let normalizedQuery = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let available = max(0, 80 - rendered("").count)
        let displayed =
            normalizedQuery.count > available
            ? String(normalizedQuery.prefix(max(0, available - 1))) + "…" : normalizedQuery
        return title(rendered(displayed))
    }

    private static func operation(
        for card: AgentToolCard, presenter: AgentToolDetailPresenter, locale: Locale, approval: Bool
    ) -> AgentToolPresentationProfile.Operation? {
        guard let operation = semantics(for: card, presenter: presenter) else { return nil }
        let argument = approval ? nil : operation.argument
        var name = argument ?? activity(operation.activity, locale: locale)
        if let count = operation.operationCount, count > 1 {
            name = AppLocalization.string("\(name) (\(count) operations)", locale: locale)
        }
        return .init(
            action: operation.action, activity: name,
            batchActivity: activity(operation.batchActivity, locale: locale), isArgument: argument != nil)
    }

    private static func activity(_ kind: AgentToolDescriptor.Presentation.ActivityKind, locale: Locale) -> String {
        switch kind {
        case .memory:
            AppLocalization.resolve(AppStrings.Assistant.memorySearchScope, locale: locale)
        case .chats:
            AppLocalization.resolve(AppStrings.Assistant.chatsSearchScope, locale: locale)
        case .init("userProfile"):
            AppLocalization.resolve(AppStrings.Assistant.userProfileSearchScope, locale: locale)
        case .skills: AppLocalization.string("skills", locale: locale)
        case .skill: AppLocalization.string("a skill", locale: locale)
        case .init("skillFiles"): AppLocalization.string("skill files", locale: locale)
        case .sessions: AppLocalization.string("saved conversations", locale: locale)
        default: kind.rawValue
        }
    }

    static func title(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
    }
}
