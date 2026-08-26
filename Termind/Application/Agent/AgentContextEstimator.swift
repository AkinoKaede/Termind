import Foundation

/// What a conversation is made of, in tokens.
///
/// `AgentTokenUsage` is the authority on *how many* — it comes from the provider
/// that did the tokenizing. This exists for the two questions that number cannot
/// answer on its own:
///
/// 1. **Before the first response.** A conversation restored from disk, or one
///    that has never run, has no reported usage at all. A gauge blank until the
///    first reply would be blank exactly when someone is deciding whether to
///    start.
/// 2. **The split.** Every provider reports one prompt total and no breakdown.
///    "62k used" answers a different question from "38k of it is tool output" —
///    only the second says what compacting would buy.
///
/// When a measured total exists the parts are **scaled to it** rather than shown
/// beside it, so the breakdown always sums to the number in the gauge above it.
/// Two numbers on one screen that disagree by 15% would leave the reader with no
/// way to tell which was wrong.
nonisolated struct AgentContextEstimate: Hashable, Sendable {
    nonisolated enum Part: String, Hashable, Sendable, CaseIterable, Identifiable {
        case systemPrompt, tools, conversation, toolResults, attachments

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .systemPrompt: String(localized: "System prompt")
            case .tools: String(localized: "Tool schemas")
            case .conversation: String(localized: "Conversation")
            case .toolResults: String(localized: "Tool results")
            case .attachments: String(localized: "Attachments")
            }
        }
    }

    /// Zero-valued parts are kept rather than dropped, so a caller can iterate
    /// `Part.allCases` and rely on a value being there.
    var parts: [Part: Int]
    var total: Int
    /// Whether `total` is the provider's count or ours. The difference is worth
    /// showing — an estimate presented as a measurement is a number people will
    /// make decisions against.
    var isMeasured: Bool

    func tokens(_ part: Part) -> Int { parts[part] ?? 0 }

    /// `nil` rather than zero when there is nothing to divide by, so a caller
    /// cannot draw a 0%-full ring for a model whose window we do not know.
    func share(of window: Int?) -> Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(total) / Double(window))
    }
}

/// The character-counting fallback behind `AgentContextEstimate`.
nonisolated enum AgentContextEstimator {
    /// Four characters to the token.
    ///
    /// The same convention `ContextChip.approximateTokens` already uses, kept as
    /// one number in one place rather than two that drift. A rough average for
    /// English prose and wrong in both directions — CJK runs nearer one token
    /// per character, minified JSON nearer two — which is the honest reason the
    /// result is labelled an estimate wherever it is shown alone.
    static let charactersPerToken = 4

    static func tokens(inCharacters count: Int) -> Int {
        count <= 0 ? 0 : max(1, count / charactersPerToken)
    }

    /// Splits a transcript into the parts a reader can act on.
    ///
    /// `toolSchemaCharacters` is passed in rather than derived: the tool
    /// registry is assembled per run in `AppModel` and a composer redrawing on
    /// every keystroke has no business rebuilding it. See
    /// `ConversationModel.noteToolSchemas(_:)`.
    static func estimate(
        systemPrompt: String,
        toolSchemaCharacters: Int,
        transcript: [AgentTranscriptMessage],
        attachedCharacters: Int,
        measured: AgentTokenUsage?
    ) -> AgentContextEstimate {
        var counted: [AgentContextEstimate.Part: Int] = [
            .systemPrompt: tokens(inCharacters: systemPrompt.count),
            .tools: tokens(inCharacters: toolSchemaCharacters),
            .attachments: tokens(inCharacters: attachedCharacters),
            .conversation: 0,
            .toolResults: 0,
        ]
        for message in transcript {
            // Tool *calls* are counted with the conversation rather than with
            // the results: they are the assistant's own words, they are small,
            // and compaction cannot remove one without removing the turn.
            let characters = message.text.count
                + message.toolCalls.reduce(0) { $0 + $1.arguments.encodedString.count }
            let part: AgentContextEstimate.Part =
                message.role == .tool ? .toolResults : .conversation
            counted[part, default: 0] += tokens(inCharacters: characters)
            counted[part, default: 0] += message.images.reduce(0) { total, image in
                let wide = max(1, Int(ceil(Double(image.pixelWidth) / 512)))
                let high = max(1, Int(ceil(Double(image.pixelHeight) / 512)))
                return total + 85 + 170 * wide * high
            }
        }

        let estimated = counted.values.reduce(0, +)
        guard let measured, !measured.isEmpty else {
            return AgentContextEstimate(
                parts: counted, total: estimated, isMeasured: false
            )
        }
        return AgentContextEstimate(
            parts: scaled(counted, from: estimated, to: measured.contextTokens),
            total: measured.contextTokens,
            isMeasured: true
        )
    }

    /// Rescales the parts so they sum to exactly `target`.
    ///
    /// The remainder from integer division is given to the largest part rather
    /// than spread or dropped, so the column adds up to the figure above it and
    /// the correction lands where it is proportionally smallest.
    private static func scaled(
        _ counted: [AgentContextEstimate.Part: Int], from estimated: Int, to target: Int
    ) -> [AgentContextEstimate.Part: Int] {
        guard estimated > 0 else { return counted }
        let ratio = Double(target) / Double(estimated)
        var result = counted.mapValues { Int((Double($0) * ratio).rounded(.down)) }
        guard let largest = result.max(by: { $0.value < $1.value })?.key else { return result }
        result[largest, default: 0] += target - result.values.reduce(0, +)
        return result
    }
}
