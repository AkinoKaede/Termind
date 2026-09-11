import Foundation
import TermindApplication

/// Turns paragraph-internal newlines into hard breaks before parsing.
///
/// CommonMark says a single newline inside a paragraph is a *soft* break and
/// renders as a space, and Foundation follows the spec — but it renders one as
/// an untagged `" "` run, indistinguishable from a typed space. So the choice
/// cannot be made after parsing; it has to be made on the source.
///
/// We make it the way GitHub's comment renderer does, because that is what
/// every chat UI does and, more to the point, because a model that wrote a
/// newline meant a line break. A reply like
///
/// ```
/// **Note:** this matters
/// Another line here
/// ```
///
/// reading as one run-on line is the bug this exists to prevent.
///
/// The mechanism is a trailing `\`, which CommonMark defines as a hard break.
/// Two trailing spaces mean the same thing but are destroyed by any whitespace
/// handling between here and the parser; a backslash is not.
///
/// Every guard below marks a place where appending a backslash would corrupt
/// something rather than break a line. The failure mode when a guard is missing
/// is benign — a stray break where a join was meant — with one exception that
/// is not: **HTML blocks carry composed attachments verbatim** in the
/// model-facing transcript. Editing a byte inside one would alter the context
/// sent to the provider, so they are skipped wholesale.
nonisolated enum MarkdownSoftBreaks {

    static func hardened(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard lines.count > 1 else { return source }

        var output: [String] = []
        output.reserveCapacity(lines.count)

        var openFence: Fence?
        var inHTMLBlock = false

        for (index, line) in lines.enumerated() {
            // Fenced code: everything between the markers is content, including
            // lines that look like prose.
            if let fence = openFence {
                if closes(line, fence) { openFence = nil }
                output.append(line)
                continue
            }
            // An HTML block runs from its opening `<` to the next blank line.
            if inHTMLBlock {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { inHTMLBlock = false }
                output.append(line)
                continue
            }
            if let fence = fence(opening: line) {
                openFence = fence
                output.append(line)
                continue
            }
            if opensHTMLBlock(line) {
                inHTMLBlock = true
                output.append(line)
                continue
            }

            guard index + 1 < lines.count else {
                output.append(line)
                continue
            }
            output.append(needsHardBreak(line, before: lines[index + 1]) ? line + "\\" : line)
        }

        return output.joined(separator: "\n")
    }

    // MARK: - The decision

    private static func needsHardBreak(_ line: String, before next: String) -> Bool {
        let current = line.trimmingCharacters(in: .whitespaces)
        let following = next.trimmingCharacters(in: .whitespaces)

        // A paragraph break already separates these; nothing to add.
        guard !current.isEmpty, !following.isEmpty else { return false }

        // Already a hard break, one way or the other.
        guard !line.hasSuffix("\\"), !line.hasSuffix("  ") else { return false }

        // Indented code blocks are content, same as fenced ones.
        guard !isIndentedCode(line), !isIndentedCode(next) else { return false }

        // A trailing backslash inside a table row corrupts the row grammar, and
        // one immediately before the delimiter row stops the table from being a
        // table at all.
        guard !current.hasPrefix("|"), !following.hasPrefix("|") else { return false }

        // The next line opens a block of its own, so a break at the end of this
        // one would either be swallowed or leave a dangling blank inside the
        // block that just closed.
        guard !following.hasPrefix("#") else { return false }
        guard fence(opening: next) == nil else { return false }
        guard !opensHTMLBlock(next) else { return false }
        guard !isThematicBreak(following) else { return false }
        guard !isSetextUnderline(following) else { return false }
        guard !isListMarker(following) else { return false }

        // A quote that starts here would absorb the break; a quote that
        // continues one wants it.
        if following.hasPrefix(">"), !current.hasPrefix(">") { return false }

        return true
    }

    // MARK: - Line shapes

    private struct Fence {
        let character: Character
        let length: Int
    }

    private static func fence(opening line: String) -> Fence? {
        let body = line.drop { $0 == " " }
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        return Fence(character: marker, length: length)
    }

    private static func closes(_ line: String, _ fence: Fence) -> Bool {
        let body = line.drop { $0 == " " }
        let run = body.prefix { $0 == fence.character }
        guard run.count >= fence.length else { return false }
        // A closing fence carries nothing but the marker.
        return body.dropFirst(run.count).allSatisfy { $0 == " " }
    }

    /// CommonMark's HTML block starts at a `<` in the leading position. We do
    /// not care which of the seven kinds it is — only that we must not touch it.
    private static func opensHTMLBlock(_ line: String) -> Bool {
        line.drop { $0 == " " }.first == "<"
    }

    private static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let body = trimmed.filter { $0 != " " }
        guard body.count >= 3 else { return false }
        guard let marker = body.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return body.allSatisfy { $0 == marker }
    }

    /// `===` under a line makes it a heading, and `---` does too — the latter
    /// already fails `isThematicBreak` only when it is shorter than three, so
    /// both runs are checked here regardless of length.
    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == "=" } || trimmed.allSatisfy { $0 == "-" }
    }

    private static func isListMarker(_ trimmed: String) -> Bool {
        if let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" {
            return trimmed.dropFirst().first == " "
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return false }
        return rest.dropFirst().first == " "
    }
}
