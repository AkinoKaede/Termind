import Foundation

/// Which fields a `/models` response actually carried for one row.
///
/// Needed because a default is indistinguishable from a value: `AIModel.kind`
/// is `.chat` whether the server said `"type": "chat"` or said nothing at all,
/// and `ModelInference` must not overwrite the first case. The decoder records
/// what it saw; inference fills only the gaps.
nonisolated struct ReportedFields: OptionSet, Sendable {
    let rawValue: Int

    static let kind = ReportedFields(rawValue: 1 << 0)
    static let input = ReportedFields(rawValue: 1 << 1)
    static let output = ReportedFields(rawValue: 1 << 2)
    static let abilities = ReportedFields(rawValue: 1 << 3)
}

/// Guesses from the model id what the endpoint did not say.
///
/// Most `/models` endpoints report an id and nothing else — `api.openai.com`
/// included — so without this a fetched list is a column of names with no
/// indication of which one can read a screenshot. Kelivo solves it the same
/// way, and this is that idea with the maintenance cost cut down.
///
/// Two rules govern the whole file:
///
/// **It only ever fills.** A field the server reported is never touched, which
/// is checked against `ReportedFields` rather than against emptiness. A good
/// gateway that sends full metadata gets nothing from this file at all.
///
/// **It is a heuristic, and it will drift.** New model families ship faster
/// than this table can be updated, and the answer to that is the per-model
/// editor in Settings rather than more regex. So the patterns stop at family
/// level and deliberately do not chase individual SKUs the way Kelivo's do —
/// encoding "a `qwen3.7-max` snapshot is multimodal only from 2026-06-08
/// onward" buys precision nobody can maintain, and a wrong chip costs two
/// clicks to fix.
nonisolated enum ModelInference {
    /// Fills the gaps in one model, in place of what the server did not report.
    ///
    /// Also used by `Add Model` with an empty `reported`, so typing `gpt-5.4`
    /// by hand arrives with its chips already ticked.
    static func fill(_ model: AIModel, reported: ReportedFields = []) -> AIModel {
        var result = model
        let id = model.id.lowercased()

        // Terminal families first: an embedding model has no tools to offer and
        // an image model reasons about nothing, so matching either one settles
        // every remaining field rather than accumulating with the rows below.
        if Self.embedding.matches(id) {
            if !reported.contains(.kind) { result.kind = .embedding }
            if !reported.contains(.input) { result.input = [.text] }
            if !reported.contains(.output) { result.output = [.text] }
            if !reported.contains(.abilities) { result.abilities = [] }
            return result
        }

        if Self.imageGeneration.matches(id) {
            if !reported.contains(.kind) { result.kind = .image }
            if !reported.contains(.input) { result.input = [.text, .image] }
            if !reported.contains(.output) { result.output = [.text, .image] }
            if !reported.contains(.abilities) { result.abilities = [] }
            return result
        }

        if !reported.contains(.input), Self.vision.matches(id) {
            result.input.insert(.image)
        }

        if !reported.contains(.abilities) {
            if Self.tools.matches(id) { result.abilities.insert(.toolCall) }
            if Self.reasoning.matches(id) { result.abilities.insert(.reasoning) }
        }

        return result
    }

    // MARK: - The table
    //
    // One entry per family, lowercased ids only, so no pattern needs a
    // case-insensitive flag. Adding a family should be adding an alternative to
    // one of these — if it takes more than that, it belongs in the editor.

    /// `text-embedding-3-large`, `bge-m3-embedding`, `embed-english-v3`.
    private static let embedding = Pattern(#"(^|[-_/])embed(ding)?s?([-._/]|$)|text-embedding"#)

    /// `dall-e-3`, `gpt-image-1`, `gemini-3-pro-image-preview`, `flux-schnell`.
    private static let imageGeneration = Pattern(#"dall-?e|(^|[-_/])image([-._/]|$)|-image-|(^|[-_/])flux([-._/]|$)"#)

    /// Reads pictures.
    private static let vision = Pattern(
        #"gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-[5-9]|(^|[-_/])o[1-9]([-._/]|$)|gemini|claude"#
            + #"|grok-[3-9]|kimi-k[2-9]|qwen.*-vl|llava|pixtral|internvl|step-3|llama-4"#
    )

    /// Can be handed a tool schema and will call it. The widest of the three —
    /// nearly every current instruction-tuned model can.
    private static let tools = Pattern(
        #"gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-[5-9]|gpt-oss|(^|[-_/])o[1-9]([-._/]|$)|gemini|claude"#
            + #"|grok-[3-9]|kimi-k[2-9]|qwen-?[3-9]|glm-[4-9]|minimax-m[2-9]|mistral|llama-[34]"#
            + #"|deepseek-(chat|v[3-9]|reasoner)|command-r|nova-(lite|pro)|step-3|internlm|intern-s1"#
    )

    /// Thinks before answering, and is billed for it.
    private static let reasoning = Pattern(
        #"gpt-[5-9]|gpt-oss|(^|[-_/])o[1-9]([-._/]|$)|gemini-(2\.5|[3-9])"#
            + #"|claude-(opus|sonnet|haiku)-[4-9]|claude-3[-.]7"#
            + #"|grok-[3-9]|kimi-k[2-9]|qwen-?[3-9]|glm-[4-9]|minimax-m[2-9]"#
            + #"|deepseek-(r1|v3\.[1-9]|v[4-9]|reasoner)|qwq|magistral|seed-thinking|intern-s1"#
    )

    /// A compiled pattern that cannot throw at the call site.
    ///
    /// The patterns are literals in this file, so a failure here is a typo
    /// caught the first time the app runs a fetch rather than a condition to
    /// handle. `matches` returning `false` on a broken pattern degrades to "we
    /// guessed nothing", which is the right failure for a heuristic.
    private struct Pattern {
        private let regex: NSRegularExpression?

        init(_ pattern: String) {
            regex = try? NSRegularExpression(pattern: pattern)
        }

        func matches(_ lowercasedID: String) -> Bool {
            guard let regex else { return false }
            let range = NSRange(lowercasedID.startIndex..., in: lowercasedID)
            return regex.firstMatch(in: lowercasedID, range: range) != nil
        }
    }
}
