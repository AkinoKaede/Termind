// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// Turns tool protocol data into the small amount of language the transcript needs.
/// Decoupled from concrete tool definitions and types: the host supplies tool-specific
/// behavior through presentation profiles and localized activity vocabulary. This
/// renderer only interprets descriptor metadata, lifecycle states and those policies.
/// Execution, approval and replay continue to use the original call and result unchanged.
nonisolated public struct AgentToolPresentation: Sendable {
    private let profile: @Sendable (AgentToolDescriptor) -> AgentToolPresentationProfile
    private let vocabulary: AgentToolPresentationVocabulary

    public init(
        profile: @escaping @Sendable (AgentToolDescriptor) -> AgentToolPresentationProfile = { _ in .init() },
        vocabulary: AgentToolPresentationVocabulary = .init()
    ) {
        self.profile = profile
        self.vocabulary = vocabulary
    }

    public enum BatchTint: Equatable, Sendable {
        case secondary, warning, success, failure
    }

    public func showsOutputTruncatedNotice(for card: AgentToolCard) -> Bool {
        truncationNotice(for: card) != nil
    }

    public func symbol(for card: AgentToolCard) -> String {
        return card.descriptor.presentation?.symbol ?? "wrench.and.screwdriver"
    }

    /// The live, user-only projection of a call waiting for approval.
    ///
    /// Approval is the one place where the person needs to inspect exactly
    /// what will be sent. Its arguments therefore remain unredacted here; the
    /// projection is derived from the in-memory request and is never attached
    /// to the durable tool card or model transcript.
    public func approval(
        for request: AgentApprovalRequest,
        presenter: AgentToolDetailPresenter? = nil,
        hostName: String? = nil,
        resourceNames: [String: AgentJSONValue] = [:],
        locale: Locale = .current
    ) -> AgentApprovalPresentation {
        let card = AgentToolCard(
            invocation: request.invocation,
            descriptor: request.descriptor,
            state: .waitingForApproval
        )
        let policy = profile(card.descriptor)
        return AgentApprovalPresentation(
            symbol: symbol(for: card),
            title: approvalSummary(for: card, hostName: hostName, locale: locale),
            detail: AgentToolDetail(
                items: policy.approvalItems(card, resourceNames, locale)
                    ?? approvalArgumentItems(
                        request.invocation.call.arguments, presenter: presenter,
                        hidesHostID: hostName != nil,
                        requiresProjection: policy.requiresArgumentProjection,
                        locale: locale),
                layout: presenter?.layout ?? .init()
            )
        )
    }

    /// Approval chrome already communicates that the call is waiting. Keep its
    /// action title short and move argument values into the reviewable detail
    /// below, where long commands and paths can scroll without hiding actions.
    private func approvalSummary(
        for card: AgentToolCard,
        hostName: String?,
        locale: Locale
    ) -> String {
        let policy = profile(card.descriptor)
        if let operation = policy.operation(card, locale, true) {
            let action = localizedActionVerb(operation.action, locale: locale)
            let title =
                usesLocalizedActionTemplates(locale)
                ? uppercaseFirst(localized("Approval tool action: \(action) \(operation.activity)", locale: locale))
                : uppercaseFirst(actionName(operation.action, form: .infinitive, locale: locale)) + " "
                    + operation.activity
            return policy.title(title)
        }
        let activity = approvalActivity(for: card, locale: locale)
        guard let kind = actionKind(for: card) else {
            let action = localized(AppStrings.Assistant.run(activity), locale: locale)
            guard let hostName, !hostName.isEmpty else { return action }
            if usesLocalizedActionTemplates(locale) {
                return localized("Approval action target: \(action) \(hostName)", locale: locale)
            }
            return "\(action) on \(hostName)"
        }

        let action = localizedActionVerb(kind, locale: locale)
        if usesLocalizedActionTemplates(locale) {
            guard let hostName, !hostName.isEmpty else {
                return uppercaseFirst(localized("Approval tool action: \(action) \(activity)", locale: locale))
            }
            return localized(
                "Approval tool action target: \(action) \(activity) \(hostName)",
                locale: locale
            )
        }

        let rendered =
            uppercaseFirst(actionName(kind, form: .infinitive, locale: locale))
            + (activity.isEmpty ? "" : " \(activity)")
        guard let hostName, !hostName.isEmpty else { return rendered }
        return "\(rendered) on \(hostName)"
    }

    private func approvalActivity(
        for card: AgentToolCard,
        locale: Locale
    ) -> String {
        if let activity = profile(card.descriptor).activity(card, locale) { return activity }
        guard let presentation = card.descriptor.presentation else {
            return humanized(card.descriptor.qualifiedName)
        }
        switch presentation.activity {
        case .label(let label):
            return label
        case .argument(_, let fallback):
            return fallback
        case .arrayCount, .localizedArrayCount, .semanticArrayCount:
            return operation(for: card, locale: locale).text
        case .semanticLabel(let kind), .semanticArgument(_, let kind):
            return activityName(kind, locale: locale)
        }
    }

    /// While work is live, use the icon of the tool(s) still in flight. After
    /// completion, a homogeneous batch keeps its tool icon; mixed batches use
    /// the generic tools symbol.
    public func batchSymbol(for cards: [AgentToolCard]) -> String {
        let unfinished = cards.filter { !$0.state.isTerminal }
        if let live = unfinished.first { return symbol(for: live) }
        guard let first = cards.first else { return "wrench.and.screwdriver" }
        let name = first.descriptor.qualifiedName
        return cards.allSatisfy { $0.descriptor.qualifiedName == name }
            ? symbol(for: first) : "wrench.and.screwdriver"
    }

    public func batchTint(for cards: [AgentToolCard]) -> BatchTint {
        if let live = cards.first(where: { !$0.state.isTerminal }) {
            return tint(for: live.state)
        }
        if !cards.isEmpty, cards.allSatisfy({ $0.state == .completed }) {
            return .success
        }
        if !cards.isEmpty, cards.allSatisfy({ $0.state == .failed || $0.state == .denied }) {
            return .failure
        }
        return .warning
    }

    /// Converts provider-authored Markdown into the one-line prose a tool
    /// batch header can accommodate. Structure and emphasis remain available
    /// in the live reasoning row; here only the visible words are reused.
    public func reasoningTitle(from markdown: String) -> String {
        TermindMarkdownParser.plainText(markdown)
    }

    public func summary(
        for card: AgentToolCard,
        hostName: String? = nil,
        locale: Locale = .current
    ) -> String {
        let policy = profile(card.descriptor)
        if let summary = policy.summary(card, locale) { return summary }
        if let operation = policy.operation(card, locale, false) {
            return policy.title(
                actionSummary(
                    operation.action, state: card.state, activity: operation.activity,
                    isArgumentValue: operation.isArgument, target: nil, locale: locale))
        }
        let operation = operation(for: card, locale: locale)
        let phase: String
        if card.state == .running {
            phase = card.result?.presentationPhase ?? card.state.rawValue
        } else if card.state == .reviewing {
            phase = AgentToolCard.State.proposed.rawValue
        } else {
            phase = card.state.rawValue
        }
        if let phaseKind = card.descriptor.presentation?.phaseKinds[phase],
            let summary = policy.phaseSummary(phaseKind, operation.text, hostName, locale)
        {
            return summary
        }
        if let actionKind = actionKind(for: card) {
            return actionSummary(
                actionKind, state: card.state, activity: operation.text,
                isArgumentValue: operation.isArgumentValue,
                target: hostName, locale: locale
            )
        }
        if let template = card.descriptor.presentation?.messages[phase] {
            var rendered = template.replacingOccurrences(of: "{activity}", with: operation.text)
            if let hostName, !hostName.isEmpty {
                rendered = rendered.replacingOccurrences(of: "{target}", with: hostName)
            } else {
                // A call may fail before its target has been resolved.
                rendered = rendered.replacingOccurrences(of: " on {target}", with: "")
                rendered = rendered.replacingOccurrences(of: " to {target}", with: "")
                rendered = rendered.replacingOccurrences(of: " with {target}", with: "")
                rendered = rendered.replacingOccurrences(of: "{target}", with: "")
            }
            return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let action: String
        switch card.state {
        case .proposed: action = localized("Preparing \(operation.text)", locale: locale)
        case .waitingForApproval:
            action = localized("Waiting to run \(operation.text)", locale: locale)
        case .waitingForUser:
            action = localized("Waiting to run \(operation.text)", locale: locale)
        case .reviewing: action = localized("Preparing \(operation.text)", locale: locale)
        case .running: action = localized("Running \(operation.text)", locale: locale)
        case .completed: action = localized("Ran \(operation.text)", locale: locale)
        case .denied: action = localized("Denied \(operation.text)", locale: locale)
        case .failed: action = localized("Failed \(operation.text)", locale: locale)
        case .interrupted: action = localized("Interrupted \(operation.text)", locale: locale)
        }

        if let hostName, !hostName.isEmpty {
            return localized("\(action) on \(hostName)", locale: locale)
        }
        return action
    }

    /// The title shown when a batch has no transient reasoning title.
    public func batchFallbackTitle(
        for cards: [AgentToolCard], hostName: (UUID) -> String?, locale: Locale = .current
    ) -> String {
        let unfinished = cards.filter { !$0.state.isTerminal }
        guard !unfinished.isEmpty else { return batchSummary(for: cards, locale: locale) }
        return unfinished.map { card in
            summary(for: card, hostName: card.invocation.targetHostID.flatMap(hostName), locale: locale)
        }.joined(separator: "; ")
    }

    /// A finished contiguous batch, phrased from the same presentation
    /// metadata as its individual rows but with repeated activities counted.
    /// Calls in different terminal states stay separate, so one failure can
    /// never be rewritten as a successful action by the batch title.
    public func batchSummary(
        for cards: [AgentToolCard], locale: Locale = .current
    ) -> String {
        if cards.count == 1, let card = cards.first, card.state == .completed,
            profile(card.descriptor).usesSummaryForSingleCompletedBatch
        {
            return summary(for: card, locale: locale)
        }
        struct Key: Hashable {
            let name: String
            let state: AgentToolCard.State
            let operationAction: AgentToolDescriptor.Presentation.ActionKind?
        }

        var order: [Key] = []
        var grouped: [Key: [AgentToolCard]] = [:]
        for card in cards {
            let key = Key(
                name: card.descriptor.qualifiedName, state: card.state,
                operationAction: profile(card.descriptor).operation(card, locale, false)?.action)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(card)
        }
        let clauses = order.compactMap { key in
            grouped[key].map { batchClause($0, locale: locale) }
        }
        return Self.joinedBatchClauses(clauses, locale: locale)
    }

    static func joinedBatchClauses(_ clauses: [String], locale: Locale) -> String {
        if locale.language.languageCode?.identifier == "ja" {
            // These clauses are sentences. The enumeration comma cannot join them.
            return clauses.joined(separator: "。")
        }
        if locale.language.languageCode?.identifier == "zh" {
            return clauses.joined(separator: "，")
        }
        if locale.language.languageCode?.identifier == "de" {
            return clauses.joined(separator: "; ")
        }
        if locale.language.languageCode?.identifier == "fr" {
            return clauses.joined(separator: "\u{202F}; ")
        }
        return clauses.enumerated()
            .map { index, clause in index == 0 ? clause : Self.lowercaseFirst(clause) }
            .joined(separator: ", ")
    }

    public func output(from result: AgentToolResult, presentation: AgentToolDescriptor.Presentation?) -> String {
        let raw = result.untrustedPayload ?? result.content
        return output(raw, policy: presentation?.output ?? .automatic)
    }

    /// The denial reason is intentionally kept both on the review record and
    /// in the tool result: people need the former and the model must receive
    /// the latter. The transcript, however, should not print identical text
    /// twice. Distinct execution failures remain visible below the review.
    public func detailOutput(
        from result: AgentToolResult,
        presentation: AgentToolDescriptor.Presentation?,
        review: GuardianDecision?
    ) -> String? {
        let rendered = output(from: result, presentation: presentation)
        guard result.isError, let review, !review.allowsExecution,
            normalized(rendered) == normalized(review.reason)
        else { return rendered }
        return nil
    }

    /// Projects protocol-shaped tool results into transcript-shaped content.
    /// The model and persistence keep the original JSON; only this projection
    /// is allowed to decide what a person sees.
    public func detail(
        for card: AgentToolCard, presenter: AgentToolDetailPresenter? = nil, locale: Locale = .current
    ) -> AgentToolDetail? {
        guard var detail = detailContent(for: card, presenter: presenter, locale: locale) else { return nil }
        detail.layout = presenter?.layout ?? .init()
        return detail
    }

    private func detailContent(
        for card: AgentToolCard, presenter: AgentToolDetailPresenter?, locale: Locale
    ) -> AgentToolDetail? {
        let policy = profile(card.descriptor)
        switch policy.detail(card, presenter, locale) {
        case .content(let detail): return detail
        case .hidden: return nil
        case .useDefault: break
        }
        guard let result = card.result else { return nil }
        if presenter == nil, policy.preservesUnprojectedJSON {
            guard
                let output = detailOutput(
                    from: result, presentation: card.descriptor.presentation, review: card.review
                )
            else { return nil }
            return AgentToolDetail(items: [.text(.init(text: output, style: .monospaced))])
        }

        let raw = result.untrustedPayload ?? result.content
        guard let value = try? AgentJSONValue.decode(Data(raw.utf8)) else {
            guard
                let output = detailOutput(
                    from: result, presentation: card.descriptor.presentation,
                    review: card.review
                )
            else { return nil }
            let text = output.isEmpty ? String(localized: "Completed without output") : output
            return AgentToolDetail(items: [
                .message(text, result.isError ? .failure : .secondary)
            ])
        }

        let isFailure = result.isError || card.state == .failed || card.state == .denied || card.state == .interrupted
        if isFailure,
            detailOutput(from: result, presentation: card.descriptor.presentation, review: card.review) == nil
        {
            return nil
        }
        guard let presenter else {
            return AgentToolDetail(
                items: AgentToolDetailFormatting.genericItems(value, locale: locale)
            )
        }
        return AgentToolDetail(
            items: presenter.present(
                .init(
                    result: value,
                    arguments: card.invocation.call.arguments.objectValue ?? [:],
                    locale: locale, isFailure: isFailure
                )))
    }

    public func truncationNotice(for card: AgentToolCard) -> String? {
        guard !profile(card.descriptor).hidesTruncationNotice else { return nil }
        return card.result?.truncateMarker
    }

    private func approvalArgumentItems(
        _ arguments: AgentJSONValue,
        presenter: AgentToolDetailPresenter?,
        hidesHostID: Bool,
        requiresProjection: Bool,
        locale: Locale
    ) -> [AgentToolDetail.Item] {
        if requiresProjection {
            guard let object = arguments.objectValue,
                let projected = presenter?.presentArguments(
                    .init(arguments: object, locale: locale))
            else { return [] }
            return projected
        }
        guard let object = arguments.objectValue else {
            return [
                .text(
                    .init(
                        title: localized("Arguments", locale: locale),
                        text: arguments.encodedString,
                        style: .monospaced
                    ))
            ]
        }

        var visible = object
        if hidesHostID { visible.removeValue(forKey: "host_id") }
        if let projected = presenter?.presentArguments(
            .init(arguments: visible, locale: locale)
        ) {
            return projected
        }
        return AgentToolDetailFormatting.genericItems(.object(visible), locale: locale)
    }

    private func output(
        _ raw: String, policy: AgentToolDescriptor.Presentation.Output
    ) -> String {
        guard let value = try? AgentJSONValue.decode(Data(raw.utf8)) else { return raw }

        if case .field(let key) = policy, let text = value.objectValue?[key]?.stringValue {
            return text
        }

        if case .automatic = policy, let object = value.objectValue {
            for key in ["content", "text", "output", "body", "diff"] {
                if let text = object[key]?.stringValue { return text }
            }
        }

        return prettyJSON(value)
    }

    private struct RenderedOperation {
        var text: String
        var isArgumentValue: Bool
    }

    private func operation(
        for card: AgentToolCard, locale: Locale
    ) -> RenderedOperation {
        if let activity = profile(card.descriptor).activity(card, locale) {
            return RenderedOperation(text: activity, isArgumentValue: false)
        }
        guard let presentation = card.descriptor.presentation else {
            return RenderedOperation(
                text: humanized(card.descriptor.qualifiedName), isArgumentValue: false
            )
        }
        switch presentation.activity {
        case .label(let label):
            return RenderedOperation(
                text: label,
                isArgumentValue: false
            )
        case .argument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                return RenderedOperation(
                    text: fallback,
                    isArgumentValue: false
                )
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return RenderedOperation(
                    text: fallback,
                    isArgumentValue: false
                )
            }
            return RenderedOperation(text: oneLine, isArgumentValue: true)
        case .arrayCount(let key, let singular, let plural, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else {
                return RenderedOperation(
                    text: fallback,
                    isArgumentValue: false
                )
            }
            return RenderedOperation(
                text: count == 1 ? singular : "\(count) \(plural)", isArgumentValue: false
            )
        case .localizedArrayCount(let key, let unit, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else {
                return RenderedOperation(
                    text: fallback,
                    isArgumentValue: false
                )
            }
            return RenderedOperation(
                text: countDescription(count, unit: unit, locale: locale),
                isArgumentValue: false
            )
        case .semanticLabel(let kind):
            return RenderedOperation(
                text: activityName(kind, locale: locale), isArgumentValue: false
            )
        case .semanticArgument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                if profile(card.descriptor).omitsMissingArgumentActivity {
                    return RenderedOperation(text: "", isArgumentValue: false)
                }
                return RenderedOperation(
                    text: activityName(fallback, locale: locale),
                    isArgumentValue: false
                )
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if profile(card.descriptor).omitsMissingArgumentActivity {
                    return RenderedOperation(text: "", isArgumentValue: false)
                }
                return RenderedOperation(
                    text: activityName(fallback, locale: locale),
                    isArgumentValue: false
                )
            }
            return RenderedOperation(text: oneLine, isArgumentValue: true)
        case .semanticArrayCount(let key, let unit, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else {
                return RenderedOperation(
                    text: activityName(fallback, locale: locale), isArgumentValue: false
                )
            }
            return RenderedOperation(
                text: countDescription(count, unit: unit, locale: locale),
                isArgumentValue: false
            )
        }
    }

    private func batchClause(
        _ cards: [AgentToolCard], locale: Locale
    ) -> String {
        guard let first = cards.first else { return "" }
        let policy = profile(first.descriptor)
        if let summary = policy.batchSummary(cards, locale) { return summary }
        if let operation = policy.batchOperation(cards, locale) {
            return policy.title(
                actionSummary(
                    operation.action, state: first.state, activity: operation.activity,
                    isArgumentValue: operation.isArgument, target: nil, locale: locale))
        }
        if let operation = policy.operation(first, locale, false) {
            if cards.count == 1 { return summary(for: first, locale: locale) }
            let activity = repeatedActivity(operation.batchActivity, count: cards.count, locale: locale)
            return policy.title(
                actionSummary(
                    operation.action, state: first.state, activity: activity,
                    isArgumentValue: false, target: nil, locale: locale))
        }
        guard let presentation = first.descriptor.presentation else {
            let activity =
                cards.count == 1
                ? operation(for: first, locale: locale)
                : semanticBatchActivity(for: first, count: cards.count, locale: locale)
                    ?? RenderedOperation(
                        text: repeatedActivity(
                            humanized(first.descriptor.qualifiedName), count: cards.count, locale: locale),
                        isArgumentValue: false
                    )
            if let actionKind = actionKind(for: first) {
                return actionSummary(
                    actionKind, state: first.state, activity: activity.text,
                    isArgumentValue: activity.isArgumentValue,
                    target: nil, locale: locale
                )
            }
            return fallbackAction(for: first.state, activity: activity.text, locale: locale)
        }

        let semanticActivity = semanticBatchActivity(
            for: first, count: cards.count, locale: locale
        )
        let activity =
            semanticActivity
            ?? batchActivity(presentation.activity, cards: cards, locale: locale)
        if let actionKind = actionKind(for: first) {
            return actionSummary(
                actionKind, state: first.state, activity: activity.text,
                isArgumentValue: activity.isArgumentValue,
                target: nil, locale: locale
            )
        }
        if let template = presentation.messages[first.state.rawValue] {
            return replacingQuotedActivity(in: template, with: activity.text)
                .replacingOccurrences(of: "{activity}", with: activity.text)
                .replacingOccurrences(of: " on {target}", with: "")
                .replacingOccurrences(of: " to {target}", with: "")
                .replacingOccurrences(of: " with {target}", with: "")
                .replacingOccurrences(of: "{target}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallbackAction(for: first.state, activity: activity.text, locale: locale)
    }

    /// Repeated calls count the activity declared by their metadata. The injected
    /// vocabulary decides whether that means objects or repeated operations.
    private func semanticBatchActivity(
        for card: AgentToolCard,
        count: Int,
        locale: Locale
    ) -> RenderedOperation? {
        guard count > 1 else { return nil }
        let kind: AgentToolDescriptor.Presentation.ActivityKind
        switch card.descriptor.presentation?.activity {
        case .semanticArgument(_, let value), .semanticLabel(let value):
            kind = value
        default: return nil
        }
        let text =
            vocabulary.countedActivity(kind, count, locale)
            ?? repeatedActivity(activityName(kind, locale: locale), count: count, locale: locale)
        return RenderedOperation(text: text, isArgumentValue: false)
    }

    private func repeatedActivity(_ activity: String, count: Int, locale: Locale) -> String {
        count == 1 ? activity : localized("\(activity) (\(count) times)", locale: locale)
    }

    private func replacingQuotedActivity(in template: String, with activity: String) -> String {
        [
            "“{activity}”", "\"{activity}\"", "‘{activity}’", "'{activity}'",
            "«{activity}»", "‹{activity}›", "「{activity}」", "『{activity}』",
        ].reduce(template) { text, quoted in
            text.replacingOccurrences(of: quoted, with: activity)
        }
    }

    private func batchActivity(
        _ activity: AgentToolDescriptor.Presentation.Activity,
        cards: [AgentToolCard], locale: Locale
    ) -> RenderedOperation {
        switch activity {
        case .localizedArrayCount(let key, let unit, let fallback):
            let count = cards.reduce(0) { total, card in
                total + (card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count ?? 0)
            }
            guard count > 0 else {
                return RenderedOperation(text: fallback, isArgumentValue: false)
            }
            return RenderedOperation(
                text: countDescription(count, unit: unit, locale: locale),
                isArgumentValue: false
            )
        case .semanticArrayCount(let key, let unit, let fallback):
            let count = cards.reduce(0) { total, card in
                total + (card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count ?? 0)
            }
            guard count > 0 else {
                return RenderedOperation(
                    text: activityName(fallback, locale: locale), isArgumentValue: false
                )
            }
            return RenderedOperation(
                text: countDescription(count, unit: unit, locale: locale),
                isArgumentValue: false
            )
        case .arrayCount(let key, let singular, let plural, let fallback):
            let count = cards.reduce(0) { total, card in
                total + (card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count ?? 0)
            }
            guard count > 0 else {
                return RenderedOperation(text: fallback, isArgumentValue: false)
            }
            return RenderedOperation(
                text: count == 1 ? singular : "\(count) \(plural)",
                isArgumentValue: false
            )
        case .argument(_, let fallback):
            return RenderedOperation(
                text: repeatedActivity(
                    fallback,
                    count: cards.count, locale: locale),
                isArgumentValue: false
            )
        case .label(let label):
            return RenderedOperation(
                text: repeatedActivity(
                    label,
                    count: cards.count, locale: locale),
                isArgumentValue: false
            )
        case .semanticArgument(_, let fallback):
            if cards.count == 1, profile(cards[0].descriptor).omitsMissingArgumentActivity {
                return operation(for: cards[0], locale: locale)
            }
            return RenderedOperation(
                text: repeatedActivity(
                    activityName(fallback, locale: locale),
                    count: cards.count, locale: locale),
                isArgumentValue: false
            )
        case .semanticLabel(let kind):
            return RenderedOperation(
                text: repeatedActivity(activityName(kind, locale: locale), count: cards.count, locale: locale),
                isArgumentValue: false
            )
        }
    }

    private func countDescription(
        _ count: Int, unit: AgentToolDescriptor.Presentation.CountedUnit, locale: Locale
    ) -> String {
        vocabulary.count(count, unit, locale)
    }

    private func fallbackAction(
        for state: AgentToolCard.State, activity: String, locale: Locale
    ) -> String {
        switch state {
        case .proposed: localized("Preparing \(activity)", locale: locale)
        case .waitingForApproval, .waitingForUser:
            localized("Waiting to run \(activity)", locale: locale)
        case .reviewing: localized("Preparing \(activity)", locale: locale)
        case .running: localized("Running \(activity)", locale: locale)
        case .completed: localized("Ran \(activity)", locale: locale)
        case .denied: localized("Denied \(activity)", locale: locale)
        case .failed: localized("Failed \(activity)", locale: locale)
        case .interrupted: localized("Interrupted \(activity)", locale: locale)
        }
    }

    private enum ActionForm { case infinitive, progressive, past }

    private struct ActionForms {
        var infinitive: String
        var progressive: String
        var past: String

        subscript(form: ActionForm) -> String {
            switch form {
            case .infinitive: infinitive
            case .progressive: progressive
            case .past: past
            }
        }
    }

    private func actionKind(
        for card: AgentToolCard
    ) -> AgentToolDescriptor.Presentation.ActionKind? {
        card.descriptor.presentation?.actionKind
    }

    private func actionSummary(
        _ kind: AgentToolDescriptor.Presentation.ActionKind,
        state: AgentToolCard.State, activity: String, isArgumentValue: Bool,
        target: String?, locale: Locale
    ) -> String {
        if usesLocalizedActionTemplates(locale) {
            let action = localizedActionVerb(kind, locale: locale)
            let displayedActivity =
                isArgumentValue
                ? quotedActivity(activity, locale: locale)
                : activity
            let rendered: String =
                switch state {
                case .proposed, .reviewing:
                    localized("Tool action preparing: \(action) \(displayedActivity)", locale: locale)
                case .waitingForApproval, .waitingForUser:
                    localized("Tool action waiting: \(action) \(displayedActivity)", locale: locale)
                case .running:
                    localized("Tool action running: \(action) \(displayedActivity)", locale: locale)
                case .completed:
                    localized("Tool action completed: \(action) \(displayedActivity)", locale: locale)
                case .denied:
                    localized("Tool action denied: \(action) \(displayedActivity)", locale: locale)
                case .failed:
                    localized("Tool action failed: \(action) \(displayedActivity)", locale: locale)
                case .interrupted:
                    localized("Tool action interrupted: \(action) \(displayedActivity)", locale: locale)
                }
            guard let target, !target.isEmpty else { return rendered }
            return localized("Tool action target: \(rendered) \(target)", locale: locale)
        }
        if activity.isEmpty {
            let rendered: String =
                switch state {
                case .proposed, .reviewing:
                    "Preparing to \(actionName(kind, form: .infinitive, locale: locale))"
                case .waitingForApproval, .waitingForUser:
                    "Waiting to \(actionName(kind, form: .infinitive, locale: locale))"
                case .running: actionName(kind, form: .progressive, locale: locale)
                case .completed: actionName(kind, form: .past, locale: locale)
                case .denied:
                    "Did not \(actionName(kind, form: .infinitive, locale: locale))"
                case .failed:
                    "Failed to \(actionName(kind, form: .infinitive, locale: locale))"
                case .interrupted:
                    "Interrupted while "
                        + Self.lowercaseFirst(actionName(kind, form: .progressive, locale: locale))
                }
            guard let target, !target.isEmpty else { return rendered }
            return "\(rendered) on \(target)"
        }
        let rendered: String
        switch state {
        case .proposed, .reviewing:
            rendered = "Preparing to \(actionName(kind, form: .infinitive, locale: locale)) \(activity)"
        case .waitingForApproval, .waitingForUser:
            rendered = "Waiting to \(actionName(kind, form: .infinitive, locale: locale)) \(activity)"
        case .running:
            rendered = "\(actionName(kind, form: .progressive, locale: locale)) \(activity)"
        case .completed:
            rendered = "\(actionName(kind, form: .past, locale: locale)) \(activity)"
        case .denied:
            rendered = "Did not \(actionName(kind, form: .infinitive, locale: locale)) \(activity)"
        case .failed:
            rendered = "Failed to \(actionName(kind, form: .infinitive, locale: locale)) \(activity)"
        case .interrupted:
            let action = Self.lowercaseFirst(actionName(kind, form: .progressive, locale: locale))
            rendered = "Interrupted while \(action) \(activity)"
        }
        guard let target, !target.isEmpty else { return rendered }
        return "\(rendered) on \(target)"
    }

    private func actionName(
        _ kind: AgentToolDescriptor.Presentation.ActionKind,
        form: ActionForm, locale: Locale
    ) -> String {
        if usesLocalizedActionTemplates(locale) { return localizedActionVerb(kind, locale: locale) }
        let forms: ActionForms =
            switch kind {
            case .call: .init(infinitive: "call", progressive: "Calling", past: "Called")
            case .cancel: .init(infinitive: "cancel", progressive: "Cancelling", past: "Cancelled")
            case .ask: .init(infinitive: "ask", progressive: "Asking", past: "Asked")
            case .compare: .init(infinitive: "compare", progressive: "Comparing", past: "Compared")
            case .copy: .init(infinitive: "copy", progressive: "Copying", past: "Copied")
            case .create: .init(infinitive: "create", progressive: "Creating", past: "Created")
            case .add: .init(infinitive: "add", progressive: "Adding", past: "Added")
            case .generate: .init(infinitive: "generate", progressive: "Generating", past: "Generated")
            case .start: .init(infinitive: "start", progressive: "Starting", past: "Started")
            case .stop: .init(infinitive: "stop", progressive: "Stopping", past: "Stopped")
            case .refresh: .init(infinitive: "refresh", progressive: "Refreshing", past: "Refreshed")
            case .delete: .init(infinitive: "delete", progressive: "Deleting", past: "Deleted")
            case .edit: .init(infinitive: "edit", progressive: "Editing", past: "Edited")
            case .fetch: .init(infinitive: "fetch", progressive: "Fetching", past: "Fetched")
            case .inspect: .init(infinitive: "inspect", progressive: "Inspecting", past: "Inspected")
            case .install: .init(infinitive: "install", progressive: "Installing", past: "Installed")
            case .list: .init(infinitive: "list", progressive: "Listing", past: "Listed")
            case .move: .init(infinitive: "move", progressive: "Moving", past: "Moved")
            case .present: .init(infinitive: "present", progressive: "Presenting", past: "Presented")
            case .provide: .init(infinitive: "provide", progressive: "Providing", past: "Provided")
            case .pull: .init(infinitive: "pull", progressive: "Pulling", past: "Pulled")
            case .push: .init(infinitive: "push", progressive: "Pushing", past: "Pushed")
            case .read: .init(infinitive: "read", progressive: "Reading", past: "Read")
            case .request: .init(infinitive: "request", progressive: "Requesting", past: "Requested")
            case .run: .init(infinitive: "run", progressive: "Running", past: "Ran")
            case .search: .init(infinitive: "search", progressive: "Searching", past: "Searched")
            case .suggest: .init(infinitive: "suggest", progressive: "Suggesting", past: "Suggested")
            case .update: .init(infinitive: "update", progressive: "Updating", past: "Updated")
            case .wait: .init(infinitive: "wait for", progressive: "Waiting for", past: "Waited for")
            case .write: .init(infinitive: "write", progressive: "Writing", past: "Wrote")
            case .changePermissions:
                .init(
                    infinitive: "change permissions for",
                    progressive: "Changing permissions for",
                    past: "Changed permissions for"
                )
            case .use: .init(infinitive: "use", progressive: "Using", past: "Used")
            // Open vocabulary. The raw value is the verb an app chose, so using it
            // uninflected reads better than a generic "act on".
            default:
                .init(
                    infinitive: kind.rawValue,
                    progressive: "\(kind.rawValue.capitalized)ing",
                    past: "\(kind.rawValue.capitalized)ed"
                )
            }
        return forms[form]
    }

    private func localizedActionVerb(
        _ kind: AgentToolDescriptor.Presentation.ActionKind, locale: Locale
    ) -> String {
        switch kind {
        case .call: localized("call", locale: locale)
        case .cancel: localized(AppStrings.Common.cancel, locale: locale)
        case .ask: localized("ask", locale: locale)
        case .compare: localized("compare", locale: locale)
        case .copy: localized("copy", locale: locale)
        case .create: localized("create", locale: locale)
        case .add: localized(AppStrings.ResourceTools.addAction, locale: locale)
        case .generate: localized(AppStrings.ResourceTools.generateAction, locale: locale)
        case .start: localized(AppStrings.ResourceTools.startAction, locale: locale)
        case .stop: localized(AppStrings.ResourceTools.stopAction, locale: locale)
        case .refresh: localized(AppStrings.ResourceTools.refreshAction, locale: locale)
        case .delete: localized("delete", locale: locale)
        case .edit: localized("edit", locale: locale)
        case .fetch: localized("fetch", locale: locale)
        case .inspect: localized("inspect", locale: locale)
        case .install: localized("install", locale: locale)
        case .list: localized("list", locale: locale)
        case .move: localized("move", locale: locale)
        case .present: localized("present", locale: locale)
        case .provide: localized("provide", locale: locale)
        case .pull: localized("pull", locale: locale)
        case .push: localized("push", locale: locale)
        case .read: localized("read", locale: locale)
        case .request: localized("request", locale: locale)
        case .run: localized("run", locale: locale)
        case .search: localized("search", locale: locale)
        case .suggest: localized("suggest", locale: locale)
        case .update: localized("update", locale: locale)
        case .wait: localized("wait for", locale: locale)
        case .write: localized("write", locale: locale)
        case .changePermissions: localized("change permissions for", locale: locale)
        case .use: localized("use", locale: locale)
        default: kind.rawValue
        }
    }

    func usesLocalizedActionTemplates(_ locale: Locale) -> Bool {
        ["de", "fr", "zh", "ja", "ko"].contains(locale.language.languageCode?.identifier ?? "")
    }

    private func quotedActivity(_ activity: String, locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "de": "„\(activity)“"
        case "fr": "«\u{00A0}\(activity)\u{00A0}»"
        case "ja": "「\(activity)」"
        case "ko": "‘\(activity)’"
        default: "“\(activity)”"
        }
    }

    private func activityName(
        _ kind: AgentToolDescriptor.Presentation.ActivityKind, locale: Locale
    ) -> String {
        vocabulary.activity(kind, locale)
    }

    private func localized(
        _ key: LocalizedStringResource, locale: Locale
    ) -> String {
        AppLocalization.resolve(key, locale: locale)
    }

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    private func uppercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + String(text.dropFirst())
    }

    public func tint(for state: AgentToolCard.State) -> BatchTint {
        switch state {
        case .denied, .failed: .failure
        case .reviewing, .waitingForApproval, .waitingForUser: .warning
        case .completed: .success
        case .proposed, .running, .interrupted: .secondary
        }
    }

    private func humanized(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func prettyJSON(_ value: AgentJSONValue) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: value.encodedData),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else { return value.encodedString }
        return String(decoding: data, as: UTF8.self)
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
