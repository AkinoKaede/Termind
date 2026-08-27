import Foundation

/// Turns tool protocol data into the small amount of language the transcript needs.
/// Execution, approval and replay continue to use the original call and result unchanged.
nonisolated enum AgentToolPresentation {
    enum BatchTint: Equatable {
        case secondary, warning, success, failure
    }

    static let displayCharacterLimit = 8_192
    static let displayLineLimit = 120

    nonisolated struct OutputPreview: Equatable, Sendable {
        let displayed: String
        let full: String
        let isShortened: Bool
        let omittedCharacters: Int
    }

    static func symbol(for card: AgentToolCard) -> String {
        return card.descriptor.presentation?.symbol ?? "wrench.and.screwdriver"
    }

    /// While work is live, use the icon of the tool(s) still in flight. After
    /// completion, a homogeneous batch keeps its tool icon; mixed batches use
    /// the generic tools symbol.
    static func batchSymbol(for cards: [AgentToolCard]) -> String {
        let unfinished = cards.filter { !$0.state.isTerminal }
        if let live = unfinished.first { return symbol(for: live) }
        guard let first = cards.first else { return "wrench.and.screwdriver" }
        let name = first.descriptor.qualifiedName
        return cards.allSatisfy { $0.descriptor.qualifiedName == name }
            ? symbol(for: first) : "wrench.and.screwdriver"
    }

    static func batchTint(for cards: [AgentToolCard]) -> BatchTint {
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

    /// A stable 30% sample for a batch. Invocation identifiers are random UUIDs,
    /// so using their first 32 bits gives the desired distribution without
    /// making a SwiftUI row redraw or scroll reuse roll the dice again.
    static func showsReasoning(forBatchID id: UUID) -> Bool {
        let sample = withUnsafeBytes(of: id.uuid) { bytes in
            bytes.prefix(4).reduce(UInt32.zero) { value, byte in
                (value << 8) | UInt32(byte)
            }
        }
        return sample < (UInt32.max / 10) * 3
    }

    /// Converts provider-authored Markdown into the one-line prose a tool
    /// batch header can accommodate. Structure and emphasis remain available
    /// in the live reasoning row; here only the visible words are reused.
    static func reasoningTitle(from markdown: String) -> String {
        let text = MarkdownDocumentParser.parse(markdown)
            .flatMap(plainText)
            .joined(separator: " ")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func summary(
        for card: AgentToolCard,
        hostName: String? = nil,
        locale: Locale = .current
    ) -> String {
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

    private static func plainText(_ block: MarkdownBlock) -> [String] {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            [inlines.map(\.text).joined()]
        case .codeBlock(_, let code):
            [code]
        case .list(let list):
            list.items.flatMap { $0.blocks.flatMap(plainText) }
        case .table(let table):
            ([table.header] + table.rows).flatMap { row in
                row.map { $0.map(\.text).joined() }
            }
        case .blockQuote(let blocks):
            blocks.flatMap(plainText)
        case .htmlBlock(let raw):
            [raw]
        case .thematicBreak:
            []
        }
    }

    /// A finished contiguous batch, phrased from the same presentation
    /// metadata as its individual rows but with repeated activities counted.
    /// Calls in different terminal states stay separate, so one failure can
    /// never be rewritten as a successful action by the batch title.
    static func batchSummary(
        for cards: [AgentToolCard], locale: Locale = .current
    ) -> String {
        struct Key: Hashable {
            let name: String
            let state: AgentToolCard.State
        }

        var order: [Key] = []
        var grouped: [Key: [AgentToolCard]] = [:]
        for card in cards {
            let key = Key(name: card.descriptor.qualifiedName, state: card.state)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(card)
        }
        let clauses = order.compactMap { key in
            grouped[key].map { batchClause($0, locale: locale) }
        }
        if locale.language.languageCode?.identifier == "zh" {
            return clauses.joined(separator: "，")
        }
        return clauses.enumerated()
            .map { index, clause in index == 0 ? clause : lowercaseFirst(clause) }
            .joined(separator: ", ")
    }

    static func output(from result: AgentToolResult) -> String {
        let raw = result.untrustedPayload ?? result.content
        return output(raw, policy: .automatic)
    }

    static func output(from result: AgentToolResult, presentation: AgentToolDescriptor.Presentation?) -> String {
        let raw = result.untrustedPayload ?? result.content
        return output(raw, policy: presentation?.output ?? .automatic)
    }

    /// The denial reason is intentionally kept both on the review record and
    /// in the tool result: people need the former and the model must receive
    /// the latter. The transcript, however, should not print identical text
    /// twice. Distinct execution failures remain visible below the review.
    static func detailOutput(
        from result: AgentToolResult,
        presentation: AgentToolDescriptor.Presentation?,
        review: SecurityReviewDecision?
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
    static func detail(
        for card: AgentToolCard, locale: Locale = .current
    ) -> AgentToolDetail? {
        guard let result = card.result else { return nil }

        // MCP output is remote-defined and intentionally keeps the established
        // JSON presentation. Built-ins below never fall back to JSON syntax.
        if card.descriptor.target == .mcp {
            guard let output = detailOutput(
                from: result, presentation: card.descriptor.presentation,
                review: card.review
            ) else { return nil }
            return AgentToolDetail(items: [
                .text(.init(title: nil, text: output, style: .monospaced))
            ])
        }

        let raw = result.untrustedPayload ?? result.content
        guard let value = try? AgentJSONValue.decode(Data(raw.utf8)) else {
            guard let output = detailOutput(
                from: result, presentation: card.descriptor.presentation,
                review: card.review
            ) else { return nil }
            let text = output.isEmpty ? String(localized: "Completed without output") : output
            return AgentToolDetail(items: [
                .message(text, result.isError ? .failure : .secondary)
            ])
        }

        let presenter: AgentToolDetailPresenter?
        if let id = card.descriptor.presentation?.detailPresenterID {
            presenter = AgentBuiltInToolDetailPresenters.presenter(id: id)
        } else {
            presenter = AgentBuiltInToolDetailPresenters.legacyPresenter(
                forToolNamed: card.descriptor.name
            )
        }
        guard let presenter else {
            return AgentToolDetail(
                items: AgentToolDetailFormatting.genericItems(value, locale: locale)
            )
        }
        return AgentToolDetail(items: presenter.present(.init(
            result: value,
            arguments: card.invocation.call.arguments.objectValue ?? [:],
            locale: locale
        )))
    }

    /// A bounded rendering projection. The full transformed output stays beside
    /// it for Copy, while the Text view only receives the small preview.
    static func preview(
        _ full: String,
        characterLimit: Int = displayCharacterLimit,
        lineLimit: Int = displayLineLimit
    ) -> OutputPreview {
        let lineCount = full.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        guard full.count > characterLimit || lineCount > lineLimit else {
            return OutputPreview(
                displayed: full, full: full, isShortened: false, omittedCharacters: 0
            )
        }

        // Five eighths at the front and three eighths at the back keeps the
        // command and initial diagnostics while retaining the final failure.
        // Leave room for the marker itself; a final tightening pass below
        // makes the bound exact even when the omitted count has many digits.
        let contentCharacterLimit = max(2, characterLimit - min(80, characterLimit / 4))
        let headCharacters = max(1, contentCharacterLimit * 5 / 8)
        let tailCharacters = max(1, contentCharacterLimit - headCharacters)
        let contentLineLimit = max(2, lineLimit - 1)
        let headLines = max(1, contentLineLimit * 5 / 8)
        let tailLines = max(1, contentLineLimit - headLines)

        let headByCharacters = full.index(
            full.startIndex,
            offsetBy: min(headCharacters, full.count)
        )
        let tailByCharacters = full.index(
            full.endIndex,
            offsetBy: -min(tailCharacters, full.count)
        )
        let headByLines = boundaryAfterLines(headLines, in: full)
        let tailByLines = boundaryBeforeLastLines(tailLines, in: full)
        var headEnd = min(headByCharacters, headByLines)
        var tailStart = max(tailByCharacters, tailByLines)

        // The limits above normally leave a gap. Keep the fallback defensive
        // for tiny custom limits used by unit tests.
        tailStart = max(tailStart, headEnd)
        var displayed = renderedPreview(full, headEnd: headEnd, tailStart: tailStart)
        while displayed.count > characterLimit, headEnd > full.startIndex || tailStart < full.endIndex {
            let overflow = displayed.count - characterLimit
            let availableHead = full.distance(from: full.startIndex, to: headEnd)
            let availableTail = full.distance(from: tailStart, to: full.endIndex)
            let dropHead = min(availableHead, max(1, overflow * 5 / 8))
            let dropTail = min(availableTail, max(0, overflow - dropHead))
            headEnd = full.index(headEnd, offsetBy: -dropHead)
            tailStart = full.index(tailStart, offsetBy: dropTail)
            displayed = renderedPreview(full, headEnd: headEnd, tailStart: tailStart)
        }
        let omitted = full.distance(from: headEnd, to: tailStart)
        return OutputPreview(
            displayed: displayed, full: full,
            isShortened: true, omittedCharacters: omitted
        )
    }

    private static func renderedPreview(
        _ full: String, headEnd: String.Index, tailStart: String.Index
    ) -> String {
        let omitted = full.distance(from: headEnd, to: tailStart)
        let marker = String(localized: "[… \(omitted) characters omitted …]")
        return String(full[..<headEnd]) + "\n\(marker)\n" + String(full[tailStart...])
    }

    private static func boundaryAfterLines(_ count: Int, in text: String) -> String.Index {
        guard count > 0 else { return text.startIndex }
        var lines = 1
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                if lines == count { return index }
                lines += 1
            }
            index = text.index(after: index)
        }
        return index
    }

    private static func boundaryBeforeLastLines(_ count: Int, in text: String) -> String.Index {
        var remaining = count
        var index = text.endIndex
        while index > text.startIndex, remaining > 0 {
            index = text.index(before: index)
            if text[index] == "\n" { remaining -= 1 }
        }
        if index < text.endIndex, text[index] == "\n" {
            return text.index(after: index)
        }
        return index
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
        guard let presentation = card.descriptor.presentation else {
            if isChinese(locale), let recovered = recoveredBuiltInOperation(
                for: card, locale: locale
            ) {
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
                text: activityName(kind, locale: locale), isArgumentValue: false
            )
        case .semanticArgument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                if card.descriptor.name == "web_search" {
                    return RenderedOperation(text: "", isArgumentValue: false)
                }
                return RenderedOperation(
                    text: activityName(fallback, locale: locale), isArgumentValue: false
                )
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if card.descriptor.name == "web_search" {
                    return RenderedOperation(text: "", isArgumentValue: false)
                }
                return RenderedOperation(
                    text: activityName(fallback, locale: locale), isArgumentValue: false
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
        let semanticArgument: (key: String, fallback: AgentToolDescriptor.Presentation.ActivityKind)? =
            switch card.descriptor.name {
            case "fetch": ("url", .url)
            case "web_search": ("query", .web)
            case "ssh_exec", "terminal_suggest": ("command", .command)
            case "sftp_list", "sftp_stat", "sftp_read", "sftp_write", "sftp_mkdir",
                "sftp_move", "sftp_chmod", "sftp_delete":
                ("path", .remoteFile)
            case "request_user_secret": ("prompt", .secret)
            case "scratch_list": ("path", .scratchWorkspace)
            case "scratch_read", "scratch_write", "scratch_edit": ("path", .scratchFile)
            case "scratch_diff": ("path_a", .scratchFiles)
            case "scratch_delete": ("path", .scratchEntry)
            case "scratch_pull", "scratch_push": ("remote_path", .remoteFile)
            case "present_plan": ("title", .plan)
            default: nil
            }
        if let semanticArgument {
            if let value = card.invocation.call.arguments.objectValue?[semanticArgument.key]?
                .stringValue
            {
                let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                if !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return RenderedOperation(text: oneLine, isArgumentValue: true)
                }
            }
            if card.descriptor.name == "web_search" {
                return RenderedOperation(text: "", isArgumentValue: false)
            }
            return RenderedOperation(
                text: activityName(semanticArgument.fallback, locale: locale),
                isArgumentValue: false
            )
        }

        let semanticLabel: AgentToolDescriptor.Presentation.ActivityKind? =
            switch card.descriptor.name {
            case "list_hosts": .hosts
            case "ssh_wait": .remoteCommand
            case "manage_tasks": .taskList
            default: nil
            }
        if let semanticLabel {
            return RenderedOperation(
                text: activityName(semanticLabel, locale: locale), isArgumentValue: false
            )
        }

        if card.descriptor.name == "request_user_input" {
            let count = card.invocation.call.arguments.objectValue?["questions"]?.arrayValue?.count
            return RenderedOperation(
                text: count.map { countDescription($0, unit: .question, locale: locale) }
                    ?? activityName(.question, locale: locale),
                isArgumentValue: false
            )
        }
        return nil
    }

    private static func batchClause(
        _ cards: [AgentToolCard], locale: Locale
    ) -> String {
        guard let first = cards.first else { return "" }
        guard let presentation = first.descriptor.presentation else {
            let activity = cards.count == 1
                ? operation(for: first, locale: locale)
                : RenderedOperation(
                    text: toolCallCount(cards.count, locale: locale), isArgumentValue: false
                )
            if let actionKind = actionKind(for: first) {
                if isChinese(locale), cards.count > 1 {
                    return repeatedActionSummary(
                        actionKind, state: first.state, count: cards.count, locale: locale
                    )
                }
                return actionSummary(
                    actionKind, state: first.state, activity: activity.text,
                    isArgumentValue: activity.isArgumentValue,
                    target: nil, locale: locale
                )
            }
            return fallbackAction(for: first.state, activity: activity.text, locale: locale)
        }

        let activity = batchActivity(presentation.activity, cards: cards, locale: locale)
        if let actionKind = actionKind(for: first) {
            if isChinese(locale), cards.count > 1 {
                return repeatedActionSummary(
                    actionKind, state: first.state, count: cards.count, locale: locale
                )
            }
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
        case .arrayCount(let key, _, _, let fallback):
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
                text: cards.count == 1 ? fallback : toolCallCount(cards.count, locale: locale),
                isArgumentValue: false
            )
        case .argument(_, let fallback):
            return cards.count == 1
                ? RenderedOperation(
                    text: legacyActivity(
                        fallback, descriptorName: cards[0].descriptor.name, locale: locale
                    ),
                    isArgumentValue: false
                )
                : RenderedOperation(
                    text: toolCallCount(cards.count, locale: locale), isArgumentValue: false
                )
        case .label(let label):
            return cards.count == 1
                ? RenderedOperation(
                    text: legacyActivity(
                        label, descriptorName: cards[0].descriptor.name, locale: locale
                    ),
                    isArgumentValue: false
                )
                : RenderedOperation(
                    text: toolCallCount(cards.count, locale: locale), isArgumentValue: false
                )
        case .semanticArgument(_, let fallback):
            if cards.count == 1, cards[0].descriptor.name == "web_search" {
                return operation(for: cards[0], locale: locale)
            }
            return RenderedOperation(
                text: cards.count == 1
                    ? activityName(fallback, locale: locale)
                    : toolCallCount(cards.count, locale: locale),
                isArgumentValue: false
            )
        case .semanticLabel(let kind):
            return RenderedOperation(
                text: cards.count == 1
                    ? activityName(kind, locale: locale)
                    : toolCallCount(cards.count, locale: locale),
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
        }
    }

    private static func toolCallCount(_ count: Int, locale: Locale) -> String {
        localized("\(count) tool calls", locale: locale)
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

    private static func actionKind(
        for card: AgentToolCard
    ) -> AgentToolDescriptor.Presentation.ActionKind? {
        if let kind = card.descriptor.presentation?.actionKind { return kind }
        return switch card.descriptor.name {
        case "fetch": .fetch
        case "web_search": .search
        case "list_hosts", "sftp_list", "scratch_list": .list
        case "ssh_wait": .wait
        case "ssh_exec": .run
        case "terminal_suggest": .suggest
        case "sftp_stat": .inspect
        case "sftp_read", "scratch_read": .read
        case "sftp_write", "scratch_write": .write
        case "sftp_mkdir": .create
        case "sftp_move": .move
        case "sftp_chmod": .changePermissions
        case "sftp_delete", "scratch_delete": .delete
        case "request_user_input": .ask
        case "request_user_secret": .request
        case "scratch_edit": .edit
        case "scratch_diff": .compare
        case "scratch_pull": .pull
        case "scratch_push": .push
        case "present_plan": .present
        case "manage_tasks": .update
        default: card.descriptor.target == .mcp ? .run : nil
        }
    }

    private static func phaseKind(
        for card: AgentToolCard, phase: String
    ) -> AgentToolDescriptor.Presentation.PhaseKind? {
        if let kind = card.descriptor.presentation?.phaseKinds[phase] { return kind }
        guard card.descriptor.name == "ssh_exec" else { return nil }
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
        if isChinese(locale) {
            let action = localizedActionVerb(kind, locale: locale)
            let displayedActivity = isArgumentValue ? "“\(activity)”" : activity
            let rendered: String = switch state {
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
            let rendered: String = switch state {
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

    private static func repeatedActionSummary(
        _ kind: AgentToolDescriptor.Presentation.ActionKind,
        state: AgentToolCard.State, count: Int, locale: Locale
    ) -> String {
        let action = localizedActionVerb(kind, locale: locale)
        switch state {
        case .failed:
            return localized("Repeated tool action failed: \(count) \(action)", locale: locale)
        case .interrupted:
            return localized(
                "Repeated tool action interrupted: \(count) \(action)", locale: locale
            )
        default:
            return actionSummary(
                kind, state: state, activity: localized("\(count) times", locale: locale),
                isArgumentValue: false, target: nil, locale: locale
            )
        }
    }

    private static func phaseSummary(
        _ kind: AgentToolDescriptor.Presentation.PhaseKind,
        activity: String, target: String?, locale: Locale
    ) -> String {
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
            } ?? localized("Connecting", locale: locale)
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
        }
    }

    private static func actionName(
        _ kind: AgentToolDescriptor.Presentation.ActionKind,
        form: ActionForm, locale: Locale
    ) -> String {
        if isChinese(locale) { return localizedActionVerb(kind, locale: locale) }
        return switch (kind, form) {
        case (.ask, .infinitive): "ask"
        case (.ask, .progressive): "Asking"
        case (.ask, .past): "Asked"
        case (.compare, .infinitive): "compare"
        case (.compare, .progressive): "Comparing"
        case (.compare, .past): "Compared"
        case (.create, .infinitive): "create"
        case (.create, .progressive): "Creating"
        case (.create, .past): "Created"
        case (.delete, .infinitive): "delete"
        case (.delete, .progressive): "Deleting"
        case (.delete, .past): "Deleted"
        case (.edit, .infinitive): "edit"
        case (.edit, .progressive): "Editing"
        case (.edit, .past): "Edited"
        case (.fetch, .infinitive): "fetch"
        case (.fetch, .progressive): "Fetching"
        case (.fetch, .past): "Fetched"
        case (.inspect, .infinitive): "inspect"
        case (.inspect, .progressive): "Inspecting"
        case (.inspect, .past): "Inspected"
        case (.list, .infinitive): "list"
        case (.list, .progressive): "Listing"
        case (.list, .past): "Listed"
        case (.move, .infinitive): "move"
        case (.move, .progressive): "Moving"
        case (.move, .past): "Moved"
        case (.present, .infinitive): "present"
        case (.present, .progressive): "Writing"
        case (.present, .past): "Presented"
        case (.pull, .infinitive): "pull"
        case (.pull, .progressive): "Pulling"
        case (.pull, .past): "Pulled"
        case (.push, .infinitive): "push"
        case (.push, .progressive): "Pushing"
        case (.push, .past): "Pushed"
        case (.read, .infinitive): "read"
        case (.read, .progressive): "Reading"
        case (.read, .past): "Read"
        case (.request, .infinitive): "request"
        case (.request, .progressive): "Requesting"
        case (.request, .past): "Requested"
        case (.run, .infinitive): "run"
        case (.run, .progressive): "Running"
        case (.run, .past): "Ran"
        case (.search, .infinitive): "search"
        case (.search, .progressive): "Searching"
        case (.search, .past): "Searched"
        case (.suggest, .infinitive): "suggest"
        case (.suggest, .progressive): "Suggesting"
        case (.suggest, .past): "Suggested"
        case (.update, .infinitive): "update"
        case (.update, .progressive): "Updating"
        case (.update, .past): "Updated"
        case (.wait, .infinitive): "wait for"
        case (.wait, .progressive): "Waiting for"
        case (.wait, .past): "Waited for"
        case (.write, .infinitive): "write"
        case (.write, .progressive): "Writing"
        case (.write, .past): "Wrote"
        case (.changePermissions, .infinitive): "change permissions for"
        case (.changePermissions, .progressive): "Changing permissions for"
        case (.changePermissions, .past): "Changed permissions for"
        case (.use, .infinitive): "use"
        case (.use, .progressive): "Using"
        case (.use, .past): "Used"
        }
    }

    private static func localizedActionVerb(
        _ kind: AgentToolDescriptor.Presentation.ActionKind, locale: Locale
    ) -> String {
        switch kind {
        case .ask: localized("ask", locale: locale)
        case .compare: localized("compare", locale: locale)
        case .create: localized("create", locale: locale)
        case .delete: localized("delete", locale: locale)
        case .edit: localized("edit", locale: locale)
        case .fetch: localized("fetch", locale: locale)
        case .inspect: localized("inspect", locale: locale)
        case .list: localized("list", locale: locale)
        case .move: localized("move", locale: locale)
        case .present: localized("present", locale: locale)
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
        }
    }

    private static func isChinese(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "zh"
    }

    private static func activityName(
        _ kind: AgentToolDescriptor.Presentation.ActivityKind, locale: Locale
    ) -> String {
        switch kind {
        case .command: localized("a command", locale: locale)
        case .hosts: localized("hosts", locale: locale)
        case .plan: localized("a plan", locale: locale)
        case .question: localized("a question", locale: locale)
        case .remoteCommand: localized("the remote command", locale: locale)
        case .remoteFile: localized("a remote file", locale: locale)
        case .scratchEntry: localized("a scratch entry", locale: locale)
        case .scratchFile: localized("a scratch file", locale: locale)
        case .scratchFiles: localized("scratch files", locale: locale)
        case .scratchWorkspace: localized("the scratch workspace", locale: locale)
        case .secret: localized("a secret", locale: locale)
        case .sshCommand: localized("the SSH command", locale: locale)
        case .taskList: localized("the task list", locale: locale)
        case .url: localized("a URL", locale: locale)
        case .web: localized("the web", locale: locale)
        }
    }

    private static func localized(
        _ key: String.LocalizationValue, locale: Locale
    ) -> String {
        AppLocalization.string(key, locale: locale)
    }

    private static func legacyActivity(
        _ fallback: String, descriptorName: String, locale: Locale
    ) -> String {
        let sftpNames = [
            "sftp_list", "sftp_stat", "sftp_read", "sftp_write", "sftp_mkdir",
            "sftp_move", "sftp_chmod", "sftp_delete",
        ]
        if sftpNames.contains(descriptorName) {
            return activityName(.remoteFile, locale: locale)
        }
        let kind: AgentToolDescriptor.Presentation.ActivityKind? = switch (
            descriptorName, fallback
        ) {
        case ("fetch", "a URL"): .url
        case ("web_search", "the web"): .web
        case ("list_hosts", "hosts"): .hosts
        case ("ssh_wait", "the remote command"): .remoteCommand
        case ("ssh_exec", "the SSH command"): .sshCommand
        case ("terminal_suggest", "a command"): .command
        case ("request_user_input", "a question"): .question
        case ("request_user_secret", "a secret"): .secret
        case ("present_plan", "a plan"): .plan
        case ("manage_tasks", "the task list"): .taskList
        case ("scratch_list", "the scratch workspace"): .scratchWorkspace
        case ("scratch_read", "a scratch file"), ("scratch_write", "a scratch file"),
            ("scratch_edit", "a scratch file"): .scratchFile
        case ("scratch_diff", "scratch files"): .scratchFiles
        case ("scratch_delete", "a scratch entry"): .scratchEntry
        case ("scratch_pull", "a remote file"), ("scratch_push", "a remote file"):
            .remoteFile
        default: nil
        }
        return kind.map { activityName($0, locale: locale) } ?? fallback
    }

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    private static func tint(for state: AgentToolCard.State) -> BatchTint {
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
