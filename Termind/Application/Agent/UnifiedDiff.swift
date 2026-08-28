import Foundation

/// Which newline a text is written with, so that reading it, changing three lines
/// and writing it back does not silently rewrite every line ending in the file.
nonisolated enum LineEnding: String, Hashable, Sendable {
    case lf, crlf

    /// Whichever appears first, matching Pi's `detectLineEnding`. A mixed file is
    /// reported as whatever it leads with and normalized to that on write, which is
    /// the only answer that makes the file more consistent rather than less.
    ///
    /// Walks unicode scalars rather than characters, and that is not a style choice:
    /// Swift treats `"\r\n"` as a *single* grapheme cluster, so `firstIndex(of:
    /// "\n")` finds nothing at all in a Windows file. Reading it as `Character`s
    /// reported `.lf` for every CRLF file, which would have rewritten every line
    /// ending in it the first time one line was edited.
    static func detected(in text: String) -> LineEnding {
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar == "\n" { return previous == "\r" ? .crlf : .lf }
            previous = scalar
        }
        return .lf
    }

    static func normalizedToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func restore(_ lfText: String) -> String {
        self == .crlf ? lfText.replacingOccurrences(of: "\n", with: "\r\n") : lfText
    }
}

/// A unified diff between two texts, and the facts a caller needs about it.
///
/// The algorithm is Swift's own: `BidirectionalCollection.difference(from:)` is a
/// Myers diff, so this type is a *formatter* over `CollectionDifference` rather than
/// a diff implementation. That is the whole reason it can exist without a
/// dependency.
///
/// Myers is fast when the two sides are similar and quadratic when they are not, so
/// `between` trims the common prefix and suffix first and refuses anything past
/// `lineLimit` in what is left. Two revisions of the same config — the case this was
/// written for — reduce to a handful of lines before the algorithm runs at all.
nonisolated struct UnifiedDiff: Hashable, Sendable {
    /// Standard `---`/`+++`/`@@` output, empty when the two sides match.
    var text: String
    var isIdentical: Bool
    var isTruncated: Bool
    /// 1-based line number, in the *new* text, of the first line that differs.
    var firstChangedLine: Int?

    static let defaultContext = 3
    static let defaultLineLimit = 10_000
    static let defaultByteLimit = 64 * 1_024

    nonisolated enum Failure: LocalizedError, Sendable, Equatable {
        case tooLarge(lines: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let lines, let limit):
                String(
                    localized: """
                        The differing region spans \(lines) lines, past the \(limit)-line diff \
                        limit. Narrow it with a bounded read of each side instead.
                        """
                )
            }
        }
    }

    /// `fromPath` and `toPath` are labels for the header, not paths that are read.
    /// They are emitted with `a/` and `b/` prefixes so the output applies under
    /// `patch -p1`.
    static func between(
        _ old: String,
        _ new: String,
        fromPath: String,
        toPath: String,
        context: Int = defaultContext,
        lineLimit: Int = defaultLineLimit,
        maximumBytes: Int = defaultByteLimit
    ) throws -> UnifiedDiff {
        guard old != new else {
            return UnifiedDiff(text: "", isIdentical: true, isTruncated: false, firstChangedLine: nil)
        }
        let (oldLines, oldEndsWithNewline) = split(old)
        let (newLines, newEndsWithNewline) = split(new)

        // Everything below works on the differing middle. `keptPrefix` is where it
        // starts in both files, which is what every line number is offset by.
        let shared = commonEdges(oldLines, newLines)
        let keptPrefix = max(0, shared.prefix - context)
        let keptSuffix = max(0, shared.suffix - context)
        let oldMiddle = Array(oldLines[keptPrefix..<(oldLines.count - keptSuffix)])
        let newMiddle = Array(newLines[keptPrefix..<(newLines.count - keptSuffix)])
        let span = max(oldMiddle.count, newMiddle.count)
        guard span <= lineLimit else { throw Failure.tooLarge(lines: span, limit: lineLimit) }

        let rows = self.rows(from: oldMiddle, to: newMiddle, offset: keptPrefix)
        guard rows.contains(where: { $0.kind != .context }) else {
            // Every line matched, so the two texts can only differ in whether the
            // last one ends with a newline. Reporting "not identical" with an empty
            // diff would be true and useless; diff(1) shows the last line leaving
            // and coming back, and so does this.
            return trailingNewlineOnly(
                oldLines, newLines,
                oldEndsWithNewline: oldEndsWithNewline, newEndsWithNewline: newEndsWithNewline,
                fromPath: fromPath, toPath: toPath,
                context: context, maximumBytes: maximumBytes
            )
        }

        var body = ""
        for hunk in hunks(in: rows, context: context) {
            body += render(
                hunk, in: rows,
                oldLineCount: oldLines.count, newLineCount: newLines.count,
                oldEndsWithNewline: oldEndsWithNewline, newEndsWithNewline: newEndsWithNewline
            )
        }

        let header = "--- a/\(fromPath)\n+++ b/\(toPath)\n"
        let (text, isTruncated) = bounded(header + body, maximumBytes: maximumBytes)
        return UnifiedDiff(
            text: text,
            isIdentical: false,
            isTruncated: isTruncated,
            firstChangedLine: firstChangedNewLine(in: rows)
        )
    }

    /// Where the divergence starts, expressed in the *new* file.
    ///
    /// Not simply the first changed row's `newNumber`: a removed row has none, and a
    /// replacement's first row is always the removal — so reading the field directly
    /// reported nothing for the single most common kind of edit. The answer for a
    /// removal is the line that now stands where the removed one did, which is the
    /// next row that exists on the new side.
    private static func firstChangedNewLine(in rows: [Row]) -> Int? {
        guard let start = rows.firstIndex(where: { $0.kind != .context }) else { return nil }
        if let number = rows[start...].lazy.compactMap(\.newNumber).first { return number }
        // Nothing follows on the new side, so the change runs to the end of the file:
        // it starts just past the last line the new side still has.
        return (rows[..<start].lazy.compactMap(\.newNumber).last ?? 0) + 1
    }

    /// The one difference that changes no line: a trailing newline gained or lost.
    private static func trailingNewlineOnly(
        _: [String], _ newLines: [String],
        oldEndsWithNewline: Bool, newEndsWithNewline: Bool,
        fromPath: String, toPath: String, context: Int, maximumBytes: Int
    ) -> UnifiedDiff {
        guard let last = newLines.last, oldEndsWithNewline != newEndsWithNewline else {
            return UnifiedDiff(
                text: "", isIdentical: false, isTruncated: false, firstChangedLine: nil
            )
        }
        let number = newLines.count
        let start = max(0, number - 1 - context)
        let leading = newLines[start..<(number - 1)]
        let span = range(start + 1, number - start)
        let marker = "\\ No newline at end of file\n"
        let body = "@@ -\(span) +\(span) @@\n"
            + leading.map { " \($0)\n" }.joined()
            + "-\(last)\n" + (oldEndsWithNewline ? "" : marker)
            + "+\(last)\n" + (newEndsWithNewline ? "" : marker)
        let (text, isTruncated) = bounded(
            "--- a/\(fromPath)\n+++ b/\(toPath)\n" + body, maximumBytes: maximumBytes
        )
        return UnifiedDiff(
            text: text, isIdentical: false, isTruncated: isTruncated, firstChangedLine: number
        )
    }

    // MARK: - Lines

    /// Splits on LF, with the trailing newline recorded rather than left as a
    /// phantom empty last line — which would otherwise render as a spurious change
    /// whenever one side ends with a newline and the other does not.
    static func split(_ text: String) -> (lines: [String], endsWithNewline: Bool) {
        guard !text.isEmpty else { return ([], true) }
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.last?.isEmpty == true
        if endsWithNewline { lines.removeLast() }
        return (lines, endsWithNewline)
    }

    private static func commonEdges(
        _ old: [String], _ new: [String]
    ) -> (prefix: Int, suffix: Int) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        return (prefix, suffix)
    }

    // MARK: - Rows

    private struct Row {
        enum Kind { case context, removed, added }
        var kind: Kind
        var text: String
        /// 1-based, and nil exactly when the row does not exist on that side.
        var oldNumber: Int?
        var newNumber: Int?
    }

    /// Replays the difference as one line-per-row script.
    ///
    /// Removals are emitted before insertions at the same position, which is what
    /// puts a replacement's `-` lines above its `+` lines in the rendered hunk.
    private static func rows(from old: [String], to new: [String], offset: Int) -> [Row] {
        let difference = new.difference(from: old)
        var removed: [Int: String] = [:]
        var added: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let index, let element, _): removed[index] = element
            case .insert(let index, let element, _): added[index] = element
            }
        }

        var rows: [Row] = []
        rows.reserveCapacity(old.count + added.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, let line = removed[oldIndex] {
                rows.append(Row(
                    kind: .removed, text: line,
                    oldNumber: offset + oldIndex + 1, newNumber: nil
                ))
                oldIndex += 1
            } else if newIndex < new.count, let line = added[newIndex] {
                rows.append(Row(
                    kind: .added, text: line,
                    oldNumber: nil, newNumber: offset + newIndex + 1
                ))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                rows.append(Row(
                    kind: .context, text: old[oldIndex],
                    oldNumber: offset + oldIndex + 1, newNumber: offset + newIndex + 1
                ))
                oldIndex += 1
                newIndex += 1
            } else {
                // Unreachable for a well-formed difference. Breaking rather than
                // trapping keeps a malformed one from taking the run down.
                break
            }
        }
        return rows
    }

    // MARK: - Hunks

    /// Row index ranges to print, each a run of changes padded by `context` and
    /// merged with its neighbour when the gap between them is nothing but context.
    private static func hunks(in rows: [Row], context: Int) -> [ClosedRange<Int>] {
        let changed = rows.indices.filter { rows[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        var start = changed[0]
        var end = changed[0]
        for index in changed.dropFirst() {
            if index - end <= context * 2 {
                end = index
            } else {
                ranges.append(start...end)
                start = index
                end = index
            }
        }
        ranges.append(start...end)

        return ranges.map { range in
            max(0, range.lowerBound - context)...min(rows.count - 1, range.upperBound + context)
        }
    }

    private static func render(
        _ hunk: ClosedRange<Int>,
        in rows: [Row],
        oldLineCount: Int,
        newLineCount: Int,
        oldEndsWithNewline: Bool,
        newEndsWithNewline: Bool
    ) -> String {
        let slice = rows[hunk]
        let oldCount = slice.count(where: { $0.kind != .added })
        let newCount = slice.count(where: { $0.kind != .removed })
        // A hunk with nothing on one side anchors at the line it follows, which is
        // what `-N,0` means to patch(1).
        let oldStart = slice.compactMap(\.oldNumber).first
            ?? rows[..<hunk.lowerBound].compactMap(\.oldNumber).last ?? 0
        let newStart = slice.compactMap(\.newNumber).first
            ?? rows[..<hunk.lowerBound].compactMap(\.newNumber).last ?? 0

        var output = "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@\n"
        for row in slice {
            switch row.kind {
            case .context: output += " \(row.text)\n"
            case .removed: output += "-\(row.text)\n"
            case .added: output += "+\(row.text)\n"
            }
            let endsOld = row.oldNumber == oldLineCount && !oldEndsWithNewline
            let endsNew = row.newNumber == newLineCount && !newEndsWithNewline
            if endsOld || endsNew { output += "\\ No newline at end of file\n" }
        }
        return output
    }

    /// `git diff` omits the count for a single line; patch(1) accepts both forms.
    private static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }

    /// Cuts at a hunk boundary where one is available, so a truncated diff is still
    /// a diff rather than a fragment ending mid-line.
    private static func bounded(_ text: String, maximumBytes: Int) -> (String, Bool) {
        guard text.utf8.count > maximumBytes else { return (text, false) }
        var kept = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = kept + line + "\n"
            if candidate.utf8.count > maximumBytes { break }
            kept = candidate
        }
        if let boundary = kept.range(of: "@@ ", options: .backwards),
            boundary.lowerBound != kept.startIndex
        {
            kept = String(kept[..<boundary.lowerBound])
        }
        return (kept, true)
    }
}
