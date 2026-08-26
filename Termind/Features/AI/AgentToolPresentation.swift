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

    static func summary(
        for card: AgentToolCard,
        hostName: String? = nil
    ) -> String {
        let operation = operationName(for: card)
        let phase: String
        if card.state == .running {
            phase = card.result?.presentationPhase ?? card.state.rawValue
        } else if card.state == .reviewing {
            phase = AgentToolCard.State.proposed.rawValue
        } else {
            phase = card.state.rawValue
        }
        if let template = card.descriptor.presentation?.messages[phase] {
            var rendered = template.replacingOccurrences(of: "{activity}", with: operation)
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
        case .proposed: action = String(localized: "Preparing \(operation)")
        case .waitingForApproval: action = String(localized: "Waiting to run \(operation)")
        case .waitingForUser: action = String(localized: "Waiting to run \(operation)")
        case .reviewing: action = String(localized: "Preparing \(operation)")
        case .running: action = String(localized: "Running \(operation)")
        case .completed: action = String(localized: "Ran \(operation)")
        case .denied: action = String(localized: "Denied \(operation)")
        case .failed: action = String(localized: "Failed \(operation)")
        case .interrupted: action = String(localized: "Interrupted \(operation)")
        }

        if let hostName, !hostName.isEmpty { return String(localized: "\(action) on \(hostName)") }
        return action
    }

    /// A finished contiguous batch, phrased from the same presentation
    /// metadata as its individual rows but with repeated activities counted.
    /// Calls in different terminal states stay separate, so one failure can
    /// never be rewritten as a successful action by the batch title.
    static func batchSummary(for cards: [AgentToolCard]) -> String {
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
        return order.compactMap { grouped[$0].map(batchClause) }
            .enumerated()
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

    private static func operationName(for card: AgentToolCard) -> String {
        guard let presentation = card.descriptor.presentation else {
            return humanized(card.descriptor.qualifiedName)
        }
        switch presentation.activity {
        case .label(let label): return label
        case .argument(let key, let fallback):
            guard let value = card.invocation.call.arguments.objectValue?[key]?.stringValue else {
                return fallback
            }
            let oneLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            return oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallback : oneLine
        case .arrayCount(let key, let singular, let plural, let fallback):
            guard let count = card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count,
                count > 0
            else { return fallback }
            return count == 1 ? singular : "\(count) \(plural)"
        }
    }

    private static func batchClause(_ cards: [AgentToolCard]) -> String {
        guard let first = cards.first else { return "" }
        guard let presentation = first.descriptor.presentation else {
            let operation = humanized(first.descriptor.qualifiedName)
            let activity = cards.count == 1
                ? operation : "\(cards.count) \(operation) calls"
            return fallbackAction(for: first.state, activity: activity)
        }

        let activity = batchActivity(presentation.activity, cards: cards)
        if let template = presentation.messages[first.state.rawValue] {
            return replacingQuotedActivity(in: template, with: activity)
                .replacingOccurrences(of: "{activity}", with: activity)
                .replacingOccurrences(of: " on {target}", with: "")
                .replacingOccurrences(of: " to {target}", with: "")
                .replacingOccurrences(of: " with {target}", with: "")
                .replacingOccurrences(of: "{target}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallbackAction(for: first.state, activity: activity)
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
        cards: [AgentToolCard]
    ) -> String {
        switch activity {
        case .arrayCount(let key, let singular, let plural, let fallback):
            let count = cards.reduce(0) { total, card in
                total + (card.invocation.call.arguments.objectValue?[key]?.arrayValue?.count ?? 0)
            }
            guard count > 0 else { return fallback }
            return count == 1 ? singular : "\(count) \(plural)"
        case .argument(_, let fallback):
            return cards.count == 1 ? fallback : counted(fallback, count: cards.count)
        case .label(let label):
            return cards.count == 1 ? label : counted(label, count: cards.count)
        }
    }

    private static func fallbackAction(
        for state: AgentToolCard.State, activity: String
    ) -> String {
        switch state {
        case .proposed: "Preparing \(activity)"
        case .waitingForApproval, .waitingForUser: "Waiting to run \(activity)"
        case .reviewing: "Preparing \(activity)"
        case .running: "Running \(activity)"
        case .completed: "Ran \(activity)"
        case .denied: "Denied \(activity)"
        case .failed: "Failed \(activity)"
        case .interrupted: "Interrupted \(activity)"
        }
    }

    private static func counted(_ phrase: String, count: Int) -> String {
        let prefixes = ["a ", "an ", "the "]
        let lower = phrase.lowercased()
        let nounPhrase = prefixes.first(where: { lower.hasPrefix($0) }).map {
            String(phrase.dropFirst($0.count))
        } ?? phrase
        return "\(count) \(pluralized(nounPhrase))"
    }

    private static func pluralized(_ phrase: String) -> String {
        guard let space = phrase.lastIndex(of: " ") else {
            return pluralizedWord(phrase)
        }
        return String(phrase[...space]) + pluralizedWord(String(phrase[phrase.index(after: space)...]))
    }

    private static func pluralizedWord(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasSuffix("s") { return word }
        if lower.hasSuffix("y"), word.count > 1 {
            return String(word.dropLast()) + "ies"
        }
        if lower.hasSuffix("ch") || lower.hasSuffix("sh") || lower.hasSuffix("x") {
            return word + "es"
        }
        return word + "s"
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
