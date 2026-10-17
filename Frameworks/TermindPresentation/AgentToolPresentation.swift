import AgentKit
import Foundation
import TermindApplication

/// Turns tool protocol data into the small amount of language the transcript needs.
/// Execution, approval and replay continue to use the original call and result unchanged.
nonisolated public enum AgentToolPresentation {
    public enum BatchTint: Equatable, Sendable {
        case secondary, warning, success, failure
    }

    public static let displayByteLimit = AgentTruncateLimits.maximumBytes
    public static let displayLineLimit = 120

    private static let chatCollaborationToolNames: Set<String> = [
        "list_models", "create_new_chat", "list_chats", "read_chat", "send_to_chat", "wait_chats",
    ]

    nonisolated public struct OutputPreview: Equatable, Sendable {
        public let displayed: String
        public let full: String
        public let isShortened: Bool
        public let omittedCharacters: Int
    }

    /// Header and approval sizing only. Every transcript result uses expandable details.
    public static func usesCompactDetails(for descriptor: AgentToolDescriptor) -> Bool {
        if isChatCollaborationTool(descriptor) { return true }
        if let kind = AgentKnowledgeToolPresentation.kind(for: descriptor) {
            return kind != .legacySkill
        }
        guard descriptor.target == .host,
            ["ssh_exec_run", "ssh_exec_output", "sftp_read"].contains(descriptor.name)
        else { return false }
        return descriptor.presentation?.presenterID.map { $0 == "builtin.\(descriptor.name)" } ?? true
    }

    public static func showsOutputTruncatedNotice(for card: AgentToolCard) -> Bool {
        truncationNotice(for: card) != nil
    }

    private static func isLocalPaneTool(_ descriptor: AgentToolDescriptor, named name: String) -> Bool {
        descriptor.target == .local && descriptor.name == name
    }

    public static func symbol(for card: AgentToolCard) -> String {
        return card.descriptor.presentation?.symbol ?? "wrench.and.screwdriver"
    }

    /// The live, user-only projection of a call waiting for approval.
    ///
    /// Approval is the one place where the person needs to inspect exactly
    /// what will be sent. Its arguments therefore remain unredacted here; the
    /// projection is derived from the in-memory request and is never attached
    /// to the durable tool card or model transcript.
    public static func approval(
        for request: AgentApprovalRequest,
        presenter: AgentToolDetailPresenter? = nil,
        hostName: String? = nil,
        locale: Locale = .current
    ) -> AgentApprovalPresentation {
        let card = AgentToolCard(
            invocation: request.invocation,
            descriptor: request.descriptor,
            state: .waitingForApproval
        )
        return AgentApprovalPresentation(
            symbol: symbol(for: card),
            title: approvalSummary(for: card, hostName: hostName, locale: locale),
            detail: AgentToolDetail(
                items: approvalArgumentItems(
                    request.invocation.call.arguments, presenter: presenter,
                    hidesHostID: hostName != nil,
                    hidesSensitiveChatArguments: isChatCollaborationTool(request.descriptor),
                    locale: locale)
            )
        )
    }

    /// Approval chrome already communicates that the call is waiting. Keep its
    /// action title short and move argument values into the reviewable detail
    /// below, where long commands and paths can scroll without hiding actions.
    private static func approvalSummary(
        for card: AgentToolCard,
        hostName: String?,
        locale: Locale
    ) -> String {
        if let operation = AgentKnowledgeToolPresentation.operation(for: card, locale: locale, approval: true) {
            let action = localizedActionVerb(operation.action, locale: locale)
            let title =
                usesLocalizedActionTemplates(locale)
                ? uppercaseFirst(localized("Approval tool action: \(action) \(operation.activity)", locale: locale))
                : uppercaseFirst(actionName(operation.action, form: .infinitive, locale: locale)) + " "
                    + operation.activity
            return AgentKnowledgeToolPresentation.title(title)
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

    private static func approvalActivity(
        for card: AgentToolCard,
        locale: Locale
    ) -> String {
        if isTerminalSuggestion(card) { return activityName(.suggestion, locale: locale) }
        guard let presentation = card.descriptor.presentation else {
            return humanized(card.descriptor.qualifiedName)
        }
        switch presentation.activity {
        case .label(let label):
            return legacyActivity(
                label, descriptorName: card.descriptor.name, locale: locale
            )
        case .argument(_, let fallback):
            return legacyActivity(
                fallback, descriptorName: card.descriptor.name, locale: locale
            )
        case .arrayCount, .localizedArrayCount, .semanticArrayCount:
            return operation(for: card, locale: locale).text
        case .semanticLabel(let kind), .semanticArgument(_, let kind):
            return activityName(resolvedActivityKind(kind, for: card), locale: locale)
        }
    }

    /// While work is live, use the icon of the tool(s) still in flight. After
    /// completion, a homogeneous batch keeps its tool icon; mixed batches use
    /// the generic tools symbol.
    public static func batchSymbol(for cards: [AgentToolCard]) -> String {
        let unfinished = cards.filter { !$0.state.isTerminal }
        if let live = unfinished.first { return symbol(for: live) }
        guard let first = cards.first else { return "wrench.and.screwdriver" }
        let name = first.descriptor.qualifiedName
        return cards.allSatisfy { $0.descriptor.qualifiedName == name }
            ? symbol(for: first) : "wrench.and.screwdriver"
    }

    public static func batchTint(for cards: [AgentToolCard]) -> BatchTint {
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
    public static func reasoningTitle(from markdown: String) -> String {
        TermindMarkdownParser.plainText(markdown)
    }

    public static func summary(
        for card: AgentToolCard,
        hostName: String? = nil,
        locale: Locale = .current
    ) -> String {
        if isLocalPaneTool(card.descriptor, named: "list_panes") {
            return AppLocalization.resolve(AppStrings.Assistant.listTerminals, locale: locale)
        }
        if isLocalPaneTool(card.descriptor, named: "read_pane") {
            let name = paneResult(for: card)?["title"]?.stringValue
            if let name, !name.isEmpty {
                return AppLocalization.resolve(AppStrings.Assistant.readTerminal(name), locale: locale)
            }
            return AppLocalization.resolve(AppStrings.Assistant.readTerminal, locale: locale)
        }
        if let summary = AgentKnowledgeToolPresentation.scopedSearchSummary(for: card, locale: locale) {
            return summary
        }
        if let operation = AgentKnowledgeToolPresentation.operation(for: card, locale: locale) {
            return AgentKnowledgeToolPresentation.title(
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
        if let phaseKind = phaseKind(for: card, phase: phase) {
            return phaseSummary(
                phaseKind, activity: operation.text, target: hostName, locale: locale
            )
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
                // A host-shaped tool is not necessarily tied to one server. In
                // particular, list_hosts and ssh_wait are not; a rejected call
                // can also fail before its host_id becomes a resolved target.
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

    /// A finished contiguous batch, phrased from the same presentation
    /// metadata as its individual rows but with repeated activities counted.
    /// Calls in different terminal states stay separate, so one failure can
    /// never be rewritten as a successful action by the batch title.
    public static func batchSummary(
        for cards: [AgentToolCard], locale: Locale = .current
    ) -> String {
        if cards.count == 1, let card = cards.first, card.state == .completed,
            isLocalPaneTool(card.descriptor, named: "list_panes")
                || isLocalPaneTool(card.descriptor, named: "read_pane")
        {
            return summary(for: card, locale: locale)
        }
        struct Key: Hashable {
            let name: String
            let state: AgentToolCard.State
            let knowledgeAction: AgentToolDescriptor.Presentation.ActionKind?
        }

        var order: [Key] = []
        var grouped: [Key: [AgentToolCard]] = [:]
        for card in cards {
            let key = Key(
                name: card.descriptor.qualifiedName, state: card.state,
                knowledgeAction: AgentKnowledgeToolPresentation.operation(for: card, locale: locale)?.action)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(card)
        }
        let clauses = order.compactMap { key in
            grouped[key].map { batchClause($0, locale: locale) }
        }
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
            .map { index, clause in index == 0 ? clause : lowercaseFirst(clause) }
            .joined(separator: ", ")
    }

    public static func output(from result: AgentToolResult, presentation: AgentToolDescriptor.Presentation?) -> String {
        let raw = result.untrustedPayload ?? result.content
        return output(raw, policy: presentation?.output ?? .automatic)
    }

    /// The denial reason is intentionally kept both on the review record and
    /// in the tool result: people need the former and the model must receive
    /// the latter. The transcript, however, should not print identical text
    /// twice. Distinct execution failures remain visible below the review.
    public static func detailOutput(
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
    public static func detail(
        for card: AgentToolCard, presenter: AgentToolDetailPresenter? = nil, locale: Locale = .current
    ) -> AgentToolDetail? {
        if let ssh = SSHExecToolPresentation.detail(for: card, locale: locale) { return ssh }
        guard let result = card.result else { return nil }

        // Terminal output belongs to the model result, never the visible card.
        // Handle these names before every raw/error/generic JSON fallback so a
        // restored card obeys the same boundary as a live one.
        if isLocalPaneTool(card.descriptor, named: "read_pane") {
            let object = paneResult(for: card) ?? [:]
            let name = object["title"]?.stringValue
            let id =
                object["pane_id"]?.stringValue
                ?? card.invocation.call.arguments.objectValue?["pane_id"]?.stringValue
            var items: [AgentToolDetail.Item] = []
            if let name {
                items.append(
                    .field(
                        .init(
                            label: AppLocalization.resolve(AppStrings.Assistant.terminalName, locale: locale),
                            value: name)))
            }
            if let id {
                items.append(
                    .field(
                        .init(
                            label: AppLocalization.resolve(AppStrings.Assistant.paneID, locale: locale),
                            value: id, isMonospaced: true)))
            }
            return AgentToolDetail(items: items)
        }
        if isLocalPaneTool(card.descriptor, named: "list_panes") {
            let panes = paneResult(for: card)?["panes"]?.arrayValue ?? []
            let rows = panes.compactMap { value -> AgentToolDetail.ListRow? in
                guard let pane = value.objectValue,
                    let title = pane["title"]?.stringValue,
                    let id = pane["pane_id"]?.stringValue
                else { return nil }
                var badges: [String] = []
                if pane["is_active"]?.boolValue == true {
                    badges.append(AppLocalization.resolve(AppStrings.Assistant.activeTerminal, locale: locale))
                }
                if pane["is_current"]?.boolValue == true {
                    badges.append(AppLocalization.resolve(AppStrings.Assistant.currentTerminal, locale: locale))
                }
                return .init(title: title, subtitle: id, badges: badges, symbol: "terminal")
            }
            return AgentToolDetail(items: [
                .list(
                    .init(
                        rows: rows,
                        emptyMessage: AppLocalization.resolve(AppStrings.Assistant.noOpenTerminals, locale: locale)
                    ))
            ])
        }

        if isChatCollaborationTool(card.descriptor) {
            let fallback = AgentToolDetail(items: [
                .message(
                    AppLocalization.resolve(AppStrings.Assistant.chatDetailsUnavailable, locale: locale),
                    result.isError ? .failure : .secondary)
            ])
            if result.isError || card.state == .failed || card.state == .denied || card.state == .interrupted {
                guard
                    detailOutput(
                        from: result, presentation: card.descriptor.presentation,
                        review: card.review) != nil
                else { return nil }
                return fallback
            }
            let raw = result.untrustedPayload ?? result.content
            guard let value = try? AgentJSONValue.decode(Data(raw.utf8)), let presenter else {
                return fallback
            }
            return AgentToolDetail(
                items: presenter.present(
                    .init(
                        result: value,
                        arguments: card.invocation.call.arguments.objectValue ?? [:],
                        locale: locale)))
        }

        // MCP output is remote-defined and intentionally keeps the established
        // JSON presentation. Built-ins below never fall back to JSON syntax.
        if card.descriptor.target == .mcp {
            guard
                let output = detailOutput(
                    from: result, presentation: card.descriptor.presentation,
                    review: card.review
                )
            else { return nil }
            return AgentToolDetail(items: [
                .text(.init(title: nil, text: output, style: .monospaced))
            ])
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

        // A failed/denied historical result may still contain success-shaped fields.
        // Only successful execution is allowed to select a knowledge success presenter.
        if let kind = AgentKnowledgeToolPresentation.kind(for: card.descriptor), kind != .legacySkill,
            result.isError || card.state == .failed || card.state == .denied || card.state == .interrupted
        {
            if detailOutput(from: result, presentation: card.descriptor.presentation, review: card.review) == nil {
                return nil
            }
            return AgentToolDetail(items: AgentToolDetailFormatting.genericItems(value, locale: locale))
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
                    locale: locale
                )))
    }

    private static func paneResult(for card: AgentToolCard) -> [String: AgentJSONValue]? {
        guard let result = card.result else { return nil }
        let raw = result.untrustedPayload ?? result.content
        return (try? AgentJSONValue.decode(Data(raw.utf8)))?.objectValue
    }

    /// A bounded rendering projection. The full transformed output stays beside
    /// it for Copy, while the Text view only receives the small preview.
    public static func preview(
        _ full: String,
        byteLimit: Int = displayByteLimit,
        lineLimit: Int = displayLineLimit
    ) -> OutputPreview {
        let selected = AgentTruncateResult.apply(
            full, strategy: .middle, limits: .init(bytes: byteLimit, lines: lineLimit))
        return OutputPreview(
            displayed: selected.content, full: full, isShortened: selected.isTruncated,
            omittedCharacters: max(0, full.count - selected.content.count))
    }

    public static func compactStrategy(for descriptor: AgentToolDescriptor) -> AgentTruncateStrategy {
        descriptor.target != .mcp
            && ["ssh_exec", "ssh_wait", "ssh_exec_run", "ssh_exec_output"].contains(descriptor.name)
            ? .tail : .head
    }

    public static func truncationNotice(for card: AgentToolCard) -> String? {
        guard !isLocalPaneTool(card.descriptor, named: "read_pane") else { return nil }
        return card.result?.truncateMarker
    }

    private static func approvalArgumentItems(
        _ arguments: AgentJSONValue,
        presenter: AgentToolDetailPresenter?,
        hidesHostID: Bool,
        hidesSensitiveChatArguments: Bool,
        locale: Locale
    ) -> [AgentToolDetail.Item] {
        if hidesSensitiveChatArguments {
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

    private static func isChatCollaborationTool(_ descriptor: AgentToolDescriptor) -> Bool {
        descriptor.target == .local && chatCollaborationToolNames.contains(descriptor.name)
    }

    private static func output(
        _ raw: String, policy: AgentToolDescriptor.Presentation.Output
    ) -> String {
        guard let value = try? AgentJSONValue.decode(Data(raw.utf8)) else { return raw }

        if case .streams = policy, let object = value.objectValue {
            let stdout = object["stdout"]?.stringValue ?? ""
            let stderr = object["stderr"]?.stringValue ?? ""
            if !stdout.isEmpty || !stderr.isEmpty {
                if stdout.isEmpty { return stderr }
                if stderr.isEmpty { return stdout }
                return String(localized: "Standard output:\n\(stdout)\nStandard error:\n\(stderr)")
            }
        }

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

    private static func operation(
        for card: AgentToolCard, locale: Locale
    ) -> RenderedOperation {
        if isTerminalSuggestion(card) {
            return RenderedOperation(text: activityName(.suggestion, locale: locale), isArgumentValue: false)
        }
        guard let presentation = card.descriptor.presentation else {
            if usesLocalizedActionTemplates(locale),
                let recovered = recoveredBuiltInOperation(
                    for: card, locale: locale
                )
            {
                return recovered
            }
            return RenderedOperation(
                text: humanized(card.descriptor.qualifiedName), isArgumentValue: false
            )
        }
        switch presentation.activity {
        case .label(let label):
            return RenderedOperation(
                text: legacyActivity(
                    label, descriptorName: card.descriptor.name, locale: locale
                ),
                isArgumentValue: false
            )
        case .argument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                return RenderedOperation(
                    text: legacyActivity(
                        fallback, descriptorName: card.descriptor.name, locale: locale
                    ),
                    isArgumentValue: false
                )
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return RenderedOperation(
                    text: legacyActivity(
                        fallback, descriptorName: card.descriptor.name, locale: locale
                    ),
                    isArgumentValue: false
                )
            }
            return RenderedOperation(text: oneLine, isArgumentValue: true)
        case .arrayCount(let key, let singular, let plural, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else {
                return RenderedOperation(
                    text: legacyActivity(
                        fallback, descriptorName: card.descriptor.name, locale: locale
                    ),
                    isArgumentValue: false
                )
            }
            if card.descriptor.name == "request_user_input" {
                return RenderedOperation(
                    text: countDescription(count, unit: .question, locale: locale),
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
                    text: legacyActivity(
                        fallback, descriptorName: card.descriptor.name, locale: locale
                    ),
                    isArgumentValue: false
                )
            }
            return RenderedOperation(
                text: countDescription(count, unit: unit, locale: locale),
                isArgumentValue: false
            )
        case .semanticLabel(let kind):
            return RenderedOperation(
                text: activityName(resolvedActivityKind(kind, for: card), locale: locale), isArgumentValue: false
            )
        case .semanticArgument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                if card.descriptor.name == "web_search" {
                    return RenderedOperation(text: "", isArgumentValue: false)
                }
                return RenderedOperation(
                    text: activityName(resolvedActivityKind(fallback, for: card), locale: locale),
                    isArgumentValue: false
                )
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if card.descriptor.name == "web_search" {
                    return RenderedOperation(text: "", isArgumentValue: false)
                }
                return RenderedOperation(
                    text: activityName(resolvedActivityKind(fallback, for: card), locale: locale),
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

    /// Cards persisted before semantic presentations were stored still know
    /// their tool name and arguments. Recover the same user-facing activity
    /// from those stable protocol fields instead of exposing names such as
    /// `web_search` in a translated summary.
    private static func recoveredBuiltInOperation(
        for card: AgentToolCard, locale: Locale
    ) -> RenderedOperation? {
        if card.descriptor.name == "request_user_input" {
            let count = card.invocation.call.arguments.objectValue?["questions"]?.arrayValue?.count
            return RenderedOperation(
                text: count.map { countDescription($0, unit: .question, locale: locale) }
                    ?? activityName(.question, locale: locale),
                isArgumentValue: false
            )
        }
        guard let metadata = legacyMetadata[card.descriptor.name] else { return nil }
        if let key = metadata.argumentKey,
            let value = card.invocation.call.arguments.objectValue?[key]?.stringValue
        {
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            if !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return RenderedOperation(text: oneLine, isArgumentValue: true)
            }
        }
        let text =
            card.descriptor.name == "web_search"
            ? "" : activityName(metadata.activity, locale: locale)
        return RenderedOperation(text: text, isArgumentValue: false)
    }

    private static func batchClause(
        _ cards: [AgentToolCard], locale: Locale
    ) -> String {
        guard let first = cards.first else { return "" }
        let listsPanes = isLocalPaneTool(first.descriptor, named: "list_panes")
        if listsPanes || isLocalPaneTool(first.descriptor, named: "read_pane") {
            // Recover the action for persisted cards whose descriptors predate
            // actionKind, and count reads/listings rather than inferred terminals.
            let activity = localized(
                listsPanes ? AppStrings.Assistant.terminalsActivity : AppStrings.Assistant.terminalActivity,
                locale: locale)
            return actionSummary(
                listsPanes ? .list : .read, state: first.state,
                activity: repeatedActivity(activity, count: cards.count, locale: locale),
                isArgumentValue: false, target: nil, locale: locale)
        }
        if isTerminalSuggestion(first) {
            let activity =
                cards.count == 1
                ? activityName(.suggestion, locale: locale)
                : localized("\(cards.count) suggestions", locale: locale)
            return actionSummary(
                .provide, state: first.state, activity: activity, isArgumentValue: false, target: nil, locale: locale)
        }
        if let operation = AgentKnowledgeToolPresentation.operation(for: first, locale: locale) {
            if cards.count == 1 { return summary(for: first, locale: locale) }
            let activity = repeatedActivity(operation.batchActivity, count: cards.count, locale: locale)
            return AgentKnowledgeToolPresentation.title(
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

    /// Repeated calls whose descriptor names a domain activity should count
    /// that activity, not expose the implementation detail that it was a tool
    /// call. A task-list call replaces the whole list, so its count describes
    /// replacements rather than pretending to know how many tasks changed.
    private static func semanticBatchActivity(
        for card: AgentToolCard,
        count: Int,
        locale: Locale
    ) -> RenderedOperation? {
        guard count > 1 else { return nil }
        let kind: AgentToolDescriptor.Presentation.ActivityKind
        switch card.descriptor.presentation?.activity {
        case .semanticArgument(_, let value), .semanticLabel(let value):
            kind = resolvedActivityKind(value, for: card)
        case .none, .argument, .label:
            guard card.descriptor.target != .mcp, let metadata = legacyMetadata[card.descriptor.name] else {
                return nil
            }
            kind = metadata.activity
        default: return nil
        }
        let text: String
        switch kind {
        case .command, .sshCommand: text = localized("\(count) commands", locale: locale)
        case .remoteFile: text = localized("\(count) files", locale: locale)
        case .remoteDirectory: text = localized("\(count) directories", locale: locale)
        case .scratchFile: text = localized("\(count) scratch files", locale: locale)
        case .scratchEntry: text = localized("\(count) scratch items", locale: locale)
        case .url: text = localized("\(count) URLs", locale: locale)
        case .plan: text = localized("\(count) plans", locale: locale)
        case .secret: text = localized("\(count) secrets", locale: locale)
        case .suggestion: text = localized("\(count) suggestions", locale: locale)
        case .taskList: text = localized("the task list \(count) times", locale: locale)
        // Lists, searches, comparisons and waits can revisit the same objects.
        // Count the repetitions without inventing a number of results or files.
        default: text = repeatedActivity(activityName(kind, locale: locale), count: count, locale: locale)
        }
        return RenderedOperation(text: text, isArgumentValue: false)
    }

    private static func repeatedActivity(_ activity: String, count: Int, locale: Locale) -> String {
        count == 1 ? activity : localized("\(activity) (\(count) times)", locale: locale)
    }

    private static func replacingQuotedActivity(in template: String, with activity: String) -> String {
        [
            "“{activity}”", "\"{activity}\"", "‘{activity}’", "'{activity}'",
            "«{activity}»", "‹{activity}›", "「{activity}」", "『{activity}』",
        ].reduce(template) { text, quoted in
            text.replacingOccurrences(of: quoted, with: activity)
        }
    }

    private static func batchActivity(
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
            if cards.first?.descriptor.name == "request_user_input" {
                return RenderedOperation(
                    text: countDescription(count, unit: .question, locale: locale),
                    isArgumentValue: false
                )
            }
            return RenderedOperation(
                text: count == 1 ? singular : "\(count) \(plural)",
                isArgumentValue: false
            )
        case .argument(_, let fallback):
            return RenderedOperation(
                text: repeatedActivity(
                    legacyActivity(fallback, descriptorName: cards[0].descriptor.name, locale: locale),
                    count: cards.count, locale: locale),
                isArgumentValue: false
            )
        case .label(let label):
            return RenderedOperation(
                text: repeatedActivity(
                    legacyActivity(label, descriptorName: cards[0].descriptor.name, locale: locale),
                    count: cards.count, locale: locale),
                isArgumentValue: false
            )
        case .semanticArgument(_, let fallback):
            if cards.count == 1, cards[0].descriptor.name == "web_search" {
                return operation(for: cards[0], locale: locale)
            }
            return RenderedOperation(
                text: repeatedActivity(
                    activityName(resolvedActivityKind(fallback, for: cards[0]), locale: locale),
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

    private static func countDescription(
        _ count: Int, unit: AgentToolDescriptor.Presentation.CountedUnit,
        locale: Locale
    ) -> String {
        switch unit {
        case .question: localized("\(count) questions", locale: locale)
        // Open vocabulary — an app that adds a unit and no resource for it gets
        // a plain count rather than a missing string.
        default: "\(count)"
        }
    }

    private static func fallbackAction(
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

    private static func actionKind(
        for card: AgentToolCard
    ) -> AgentToolDescriptor.Presentation.ActionKind? {
        if isTerminalSuggestion(card) { return .provide }
        if let kind = card.descriptor.presentation?.actionKind { return kind }
        return legacyMetadata[card.descriptor.name]?.action
            ?? (card.descriptor.target == .mcp ? .run : nil)
    }

    private static func phaseKind(
        for card: AgentToolCard, phase: String
    ) -> AgentToolDescriptor.Presentation.PhaseKind? {
        if let kind = card.descriptor.presentation?.phaseKinds[phase] { return kind }
        guard ["ssh_exec", "ssh_exec_run"].contains(card.descriptor.name) else { return nil }
        return switch phase {
        case "proposed": .sshPreparingCommand
        case "waitingForApproval": .sshWaitingForCommand
        case "waitingForUser": .sshWaitingForAuthentication
        case "running": .sshConnecting
        case "command": .sshRunningCommand
        case "completed": .sshCompletedCommand
        case "denied": .sshDeniedCommand
        case "failed": .sshFailedCommand
        case "interrupted": .sshInterruptedCommand
        default: nil
        }
    }

    private static func actionSummary(
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
                        + lowercaseFirst(actionName(kind, form: .progressive, locale: locale))
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
            let action = lowercaseFirst(actionName(kind, form: .progressive, locale: locale))
            rendered = "Interrupted while \(action) \(activity)"
        }
        guard let target, !target.isEmpty else { return rendered }
        return "\(rendered) on \(target)"
    }

    private static func phaseSummary(
        _ kind: AgentToolDescriptor.Presentation.PhaseKind,
        activity: String, target: String?, locale: Locale
    ) -> String {
        // Commands already carry their own shell punctuation. English reads
        // more naturally without another pair of prose quotes around the
        // entire command, while Chinese and Japanese use quotation marks to separate the
        // command from the surrounding sentence.
        if !usesLocalizedActionTemplates(locale) {
            return switch kind {
            case .sshPreparingCommand:
                target.map { "Preparing to run \(activity) on \($0)" }
                    ?? "Preparing to run \(activity)"
            case .sshWaitingForCommand:
                target.map { "Waiting to run \(activity) on \($0)" }
                    ?? "Waiting to run \(activity)"
            case .sshWaitingForAuthentication:
                target.map { "Waiting to authenticate with \($0)" }
                    ?? "Waiting for authentication"
            case .sshConnecting:
                target.map { "Connecting to \($0)" } ?? "Connecting"
            case .sshRunningCommand:
                target.map { "Running \(activity) on \($0)" } ?? "Running \(activity)"
            case .sshCompletedCommand:
                target.map { "Ran \(activity) on \($0)" } ?? "Ran \(activity)"
            case .sshDeniedCommand:
                target.map { "Did not run \(activity) on \($0)" }
                    ?? "Did not run \(activity)"
            case .sshFailedCommand:
                target.map { "Failed to run \(activity) on \($0)" }
                    ?? "Failed to run \(activity)"
            case .sshInterruptedCommand:
                target.map { "Stopped waiting for \(activity) on \($0)" }
                    ?? "Stopped waiting for \(activity)"
            default: activity
            }
        }
        switch kind {
        case .sshPreparingCommand:
            return target.map {
                localized("Preparing to run “\(activity)” on \($0)", locale: locale)
            } ?? localized("Preparing to run “\(activity)”", locale: locale)
        case .sshWaitingForCommand:
            return target.map {
                localized("Waiting to run “\(activity)” on \($0)", locale: locale)
            } ?? localized("Waiting to run “\(activity)”", locale: locale)
        case .sshWaitingForAuthentication:
            return target.map {
                localized("Waiting to authenticate with \($0)", locale: locale)
            } ?? localized("Waiting for authentication", locale: locale)
        case .sshConnecting:
            return target.map {
                localized("Connecting to \($0)", locale: locale)
            } ?? localized(AppStrings.Connections.connecting, locale: locale)
        case .sshRunningCommand:
            return target.map {
                localized("Running “\(activity)” on \($0)", locale: locale)
            } ?? localized("Running “\(activity)”", locale: locale)
        case .sshCompletedCommand:
            return target.map {
                localized("Ran “\(activity)” on \($0)", locale: locale)
            } ?? localized("Ran “\(activity)”", locale: locale)
        case .sshDeniedCommand:
            return target.map {
                localized("Did not run “\(activity)” on \($0)", locale: locale)
            } ?? localized("Did not run “\(activity)”", locale: locale)
        case .sshFailedCommand:
            return target.map {
                localized("Failed to run “\(activity)” on \($0)", locale: locale)
            } ?? localized("Failed to run “\(activity)”", locale: locale)
        case .sshInterruptedCommand:
            return target.map {
                localized("Stopped waiting for “\(activity)” on \($0)", locale: locale)
            } ?? localized("Stopped waiting for “\(activity)”", locale: locale)
        // Open vocabulary. A phase this app has no wording for falls back to the
        // ordinary action lifecycle, which is what the caller does with `nil`.
        default:
            return activity
        }
    }

    private static func actionName(
        _ kind: AgentToolDescriptor.Presentation.ActionKind,
        form: ActionForm, locale: Locale
    ) -> String {
        if usesLocalizedActionTemplates(locale) { return localizedActionVerb(kind, locale: locale) }
        let forms: ActionForms =
            switch kind {
            case .cancel: .init(infinitive: "cancel", progressive: "Cancelling", past: "Cancelled")
            case .ask: .init(infinitive: "ask", progressive: "Asking", past: "Asked")
            case .compare: .init(infinitive: "compare", progressive: "Comparing", past: "Compared")
            case .copy: .init(infinitive: "copy", progressive: "Copying", past: "Copied")
            case .create: .init(infinitive: "create", progressive: "Creating", past: "Created")
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

    private static func localizedActionVerb(
        _ kind: AgentToolDescriptor.Presentation.ActionKind, locale: Locale
    ) -> String {
        switch kind {
        case .cancel: localized(AppStrings.Common.cancel, locale: locale)
        case .ask: localized("ask", locale: locale)
        case .compare: localized("compare", locale: locale)
        case .copy: localized("copy", locale: locale)
        case .create: localized("create", locale: locale)
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

    private static func usesLocalizedActionTemplates(_ locale: Locale) -> Bool {
        ["de", "fr", "zh", "ja", "ko"].contains(locale.language.languageCode?.identifier ?? "")
    }

    private static func quotedActivity(_ activity: String, locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "de": "„\(activity)“"
        case "fr": "«\u{00A0}\(activity)\u{00A0}»"
        case "ja": "「\(activity)」"
        case "ko": "‘\(activity)’"
        default: "“\(activity)”"
        }
    }

    private static func activityName(
        _ kind: AgentToolDescriptor.Presentation.ActivityKind, locale: Locale
    ) -> String {
        switch kind {
        case .command: localized("a command", locale: locale)
        case .commandOutput: localized(AppStrings.SSHExec.commandOutput, locale: locale)
        case .hosts: localized("hosts", locale: locale)
        case .metrics: localized("host metrics", locale: locale)
        case .plan: localized("a plan", locale: locale)
        case .question: localized("a question", locale: locale)
        case .remoteCommand: localized("the remote command", locale: locale)
        case .remoteFile: localized("a file", locale: locale)
        case .remoteDirectory: localized("a directory", locale: locale)
        case .scratchEntry: localized("a scratch entry", locale: locale)
        case .scratchFile: localized("a scratch file", locale: locale)
        case .scratchFiles: localized("scratch files", locale: locale)
        case .scratchWorkspace: localized("the scratch workspace", locale: locale)
        case .secret: localized("a secret", locale: locale)
        case .skill: localized("a skill", locale: locale)
        case .skills: localized("skills", locale: locale)
        case .memory: localized(AppStrings.Assistant.memorySearchScope, locale: locale)
        case .sessions: localized("saved conversations", locale: locale)
        case .sshCommand: localized("a command", locale: locale)
        case .suggestion: localized("a suggestion", locale: locale)
        case .taskList: localized("the task list", locale: locale)
        case .url: localized("a URL", locale: locale)
        case .web: localized("the web", locale: locale)
        default: kind.rawValue
        }
    }

    private static func localized(
        _ key: LocalizedStringResource, locale: Locale
    ) -> String {
        AppLocalization.resolve(key, locale: locale)
    }

    private static func legacyActivity(
        _ fallback: String, descriptorName: String, locale: Locale
    ) -> String {
        guard let metadata = legacyMetadata[descriptorName] else { return fallback }
        let legacyFallback = activityName(metadata.activity, locale: Locale(identifier: "en"))
        let oldFallback =
            (metadata.activity == .sshCommand && fallback == "the SSH command")
            || (metadata.activity == .remoteFile && fallback == "a remote file")
        guard metadata.localizesAnyFallback || fallback == legacyFallback || oldFallback else { return fallback }
        return activityName(metadata.activity, locale: locale)
    }

    /// Older semantic descriptors used the file noun for directory operations too.
    private static func resolvedActivityKind(
        _ kind: AgentToolDescriptor.Presentation.ActivityKind, for card: AgentToolCard
    ) -> AgentToolDescriptor.Presentation.ActivityKind {
        if kind == .remoteCommand, card.descriptor.target == .host, card.descriptor.name == "ssh_exec_output" {
            return .commandOutput
        }
        if kind == .remoteFile, card.descriptor.target == .host,
            ["sftp_list", "sftp_mkdir"].contains(card.descriptor.name)
        {
            return .remoteDirectory
        }
        return kind
    }

    /// Suggestions create a user-operated card; historical descriptors must not
    /// turn their command argument into an execution claim in the transcript.
    private static func isTerminalSuggestion(_ card: AgentToolCard) -> Bool {
        card.descriptor.target == .user && card.descriptor.name == "terminal_suggest"
    }

    private struct LegacyMetadata {
        var argumentKey: String?
        var activity: AgentToolDescriptor.Presentation.ActivityKind
        var action: AgentToolDescriptor.Presentation.ActionKind
        var localizesAnyFallback = false
    }

    private static let legacyMetadata: [String: LegacyMetadata] = [
        "fetch": .init(argumentKey: "url", activity: .url, action: .fetch),
        "web_search": .init(argumentKey: "query", activity: .web, action: .search),
        "list_hosts": .init(argumentKey: nil, activity: .hosts, action: .list),
        "get_metrics": .init(argumentKey: nil, activity: .metrics, action: .read),
        "ssh_wait": .init(argumentKey: nil, activity: .remoteCommand, action: .wait),
        "ssh_exec": .init(argumentKey: "command", activity: .sshCommand, action: .run),
        "terminal_suggest": .init(argumentKey: nil, activity: .suggestion, action: .provide),
        "sftp_list": .init(
            argumentKey: "path", activity: .remoteDirectory, action: .list,
            localizesAnyFallback: true
        ),
        "sftp_stat": .init(
            argumentKey: "path", activity: .remoteFile, action: .inspect,
            localizesAnyFallback: true
        ),
        "sftp_read": .init(
            argumentKey: "path", activity: .remoteFile, action: .read,
            localizesAnyFallback: true
        ),
        "sftp_write": .init(
            argumentKey: "path", activity: .remoteFile, action: .write,
            localizesAnyFallback: true
        ),
        "sftp_mkdir": .init(
            argumentKey: "path", activity: .remoteDirectory, action: .create,
            localizesAnyFallback: true
        ),
        "sftp_move": .init(
            argumentKey: "path", activity: .remoteFile, action: .move,
            localizesAnyFallback: true
        ),
        "sftp_chmod": .init(
            argumentKey: "path", activity: .remoteFile, action: .changePermissions,
            localizesAnyFallback: true
        ),
        "sftp_delete": .init(
            argumentKey: "path", activity: .remoteFile, action: .delete,
            localizesAnyFallback: true
        ),
        "request_user_input": .init(argumentKey: nil, activity: .question, action: .ask),
        "request_user_secret": .init(argumentKey: "prompt", activity: .secret, action: .request),
        "scratch_list": .init(
            argumentKey: "path", activity: .scratchWorkspace, action: .list
        ),
        "scratch_read": .init(argumentKey: "path", activity: .scratchFile, action: .read),
        "scratch_search": .init(argumentKey: "query", activity: .scratchWorkspace, action: .search),
        "scratch_copy": .init(argumentKey: "from", activity: .scratchEntry, action: .copy),
        "scratch_move": .init(argumentKey: "from", activity: .scratchEntry, action: .move),
        "scratch_fetch": .init(argumentKey: "url", activity: .url, action: .fetch),
        "sftp_copy": .init(argumentKey: "source_path", activity: .remoteFile, action: .copy),
        "scratch_write": .init(argumentKey: "path", activity: .scratchFile, action: .write),
        "scratch_edit": .init(argumentKey: "path", activity: .scratchFile, action: .edit),
        "scratch_diff": .init(
            argumentKey: "path_a", activity: .scratchFiles, action: .compare
        ),
        "scratch_delete": .init(
            argumentKey: "path", activity: .scratchEntry, action: .delete
        ),
        "scratch_pull": .init(
            argumentKey: "remote_path", activity: .remoteFile, action: .pull
        ),
        "scratch_push": .init(
            argumentKey: "remote_path", activity: .remoteFile, action: .push
        ),
        "present_plan": .init(argumentKey: "title", activity: .plan, action: .present),
        "manage_tasks": .init(argumentKey: nil, activity: .taskList, action: .update),
    ]

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    private static func uppercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + String(text.dropFirst())
    }

    public static func tint(for state: AgentToolCard.State) -> BatchTint {
        switch state {
        case .denied, .failed: .failure
        case .reviewing, .waitingForApproval, .waitingForUser: .warning
        case .completed: .success
        case .proposed, .running, .interrupted: .secondary
        }
    }

    private static func humanized(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func prettyJSON(_ value: AgentJSONValue) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: value.encodedData),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else { return value.encodedString }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
