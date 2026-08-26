import Foundation
import Testing

@testable import Termind

/// Every expectation below was checked against GNU `diff -u` before it was written
/// down: for each case the generated text is byte-identical to `diff -u --label a/f
/// --label b/f`, and `patch -p1` applies it to the old file and reproduces the new
/// one exactly. Asserting the literal output is therefore asserting conformance to
/// the real format rather than to whatever this implementation happened to emit.
@Suite
struct UnifiedDiffTests {

    // MARK: - Line endings

    @Test
    func lineEndingIsWhicheverComesFirstAndSurvivesARoundTrip() {
        #expect(LineEnding.detected(in: "a\nb\n") == .lf)
        #expect(LineEnding.detected(in: "a\r\nb\r\n") == .crlf)
        #expect(LineEnding.detected(in: "no newline at all") == .lf)
        // Mixed reports what it leads with, and normalizing to that is the only
        // answer that leaves the file more consistent than it found it.
        #expect(LineEnding.detected(in: "a\r\nb\nc") == .crlf)

        #expect(LineEnding.normalizedToLF("a\r\nb\rc\n") == "a\nb\nc\n")
        #expect(LineEnding.crlf.restore("a\nb\n") == "a\r\nb\r\n")
        #expect(LineEnding.lf.restore("a\nb\n") == "a\nb\n")
    }

    // MARK: - Identity

    @Test
    func identicalTextsProduceNoHunk() throws {
        let diff = try UnifiedDiff.between("a\nb\n", "a\nb\n", fromPath: "f", toPath: "f")
        #expect(diff.isIdentical)
        #expect(diff.text.isEmpty)
        #expect(diff.firstChangedLine == nil)
    }

    // MARK: - Shapes

    @Test
    func replacementPutsRemovalsAboveInsertions() throws {
        let diff = try UnifiedDiff.between(
            "a\nb\nc\nd\ne\nf\ng\n", "a\nb\nc\nX\ne\nf\ng\n", fromPath: "f", toPath: "f"
        )
        #expect(diff.text == """
            --- a/f
            +++ b/f
            @@ -1,7 +1,7 @@
             a
             b
             c
            -d
            +X
             e
             f
             g

            """)
        // The regression this pins: the first changed row of a replacement is the
        // removal, which has no line number on the new side. Reading the field
        // directly reported nothing at all for the commonest kind of edit.
        #expect(diff.firstChangedLine == 4)
    }

    @Test
    func insertionAndDeletionCountTheirSidesCorrectly() throws {
        let inserted = try UnifiedDiff.between(
            "a\nb\nc\n", "a\nb\nNEW\nc\n", fromPath: "f", toPath: "f"
        )
        #expect(inserted.text.contains("@@ -1,3 +1,4 @@"))
        #expect(inserted.firstChangedLine == 3)

        let deleted = try UnifiedDiff.between("a\nb\nc\n", "a\nc\n", fromPath: "f", toPath: "f")
        #expect(deleted.text.contains("@@ -1,3 +1,2 @@"))
        // Where the divergence now stands in the new file, not where it was.
        #expect(deleted.firstChangedLine == 2)
    }

    /// `git diff` writes a one-line range without its count, and so does this.
    @Test
    func aSingleLineRangeOmitsItsCount() throws {
        let diff = try UnifiedDiff.between("a\n", "a\nb\n", fromPath: "f", toPath: "f")
        #expect(diff.text.contains("@@ -1 +1,2 @@"))
    }

    @Test
    func distantChangesBecomeSeparateHunksAtTheRightOffsets() throws {
        let old = (1...30).map { "L\($0)" }.joined(separator: "\n") + "\n"
        let new = (1...30).map { line -> String in
            switch line {
            case 3: "L3-changed"
            case 25: "L25-changed"
            default: "L\(line)"
            }
        }.joined(separator: "\n") + "\n"

        let diff = try UnifiedDiff.between(old, new, fromPath: "f", toPath: "f")
        #expect(diff.text.contains("@@ -1,6 +1,6 @@"))
        #expect(diff.text.contains("@@ -22,7 +22,7 @@"))
        #expect(diff.text.components(separatedBy: "@@ -").count == 3)
        #expect(diff.firstChangedLine == 3)
    }

    @Test
    func nearbyChangesMergeIntoOneHunk() throws {
        let old = (1...20).map { "L\($0)" }.joined(separator: "\n") + "\n"
        let new = (1...20).map { $0 == 8 || $0 == 11 ? "L\($0)-changed" : "L\($0)" }
            .joined(separator: "\n") + "\n"
        let diff = try UnifiedDiff.between(old, new, fromPath: "f", toPath: "f")
        // Two changes three lines apart share their context rather than printing it
        // twice with a redundant header between.
        #expect(diff.text.components(separatedBy: "@@ -").count == 2)
    }

    // MARK: - Trailing newline

    /// The one difference that changes no line. Reporting "not identical" with an
    /// empty diff was true and useless.
    @Test
    func aMissingTrailingNewlineIsShownRatherThanImplied() throws {
        let diff = try UnifiedDiff.between("a\nb\n", "a\nb", fromPath: "f", toPath: "f")
        #expect(!diff.isIdentical)
        #expect(diff.text == """
            --- a/f
            +++ b/f
            @@ -1,2 +1,2 @@
             a
            -b
            +b
            \\ No newline at end of file

            """)
        #expect(diff.firstChangedLine == 2)
    }

    @Test
    func theMarkerAppearsOnWhicheverSidesLackTheNewline() throws {
        let diff = try UnifiedDiff.between("a\nb\nc", "a\nb\nX", fromPath: "f", toPath: "f")
        #expect(diff.text == """
            --- a/f
            +++ b/f
            @@ -1,3 +1,3 @@
             a
             b
            -c
            \\ No newline at end of file
            +X
            \\ No newline at end of file

            """)
    }

    // MARK: - Bounds

    @Test
    func outputPastTheByteLimitIsTruncatedAtAHunkBoundary() throws {
        let old = (1...400).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (1...400).map { $0 % 10 == 0 ? "line \($0) changed" : "line \($0)" }
            .joined(separator: "\n") + "\n"
        let diff = try UnifiedDiff.between(
            old, new, fromPath: "f", toPath: "f", maximumBytes: 512
        )
        #expect(diff.isTruncated)
        #expect(diff.text.utf8.count <= 512)
        // Still a diff, not a fragment ending mid-hunk.
        #expect(diff.text.hasPrefix("--- a/f\n+++ b/f\n"))
        #expect(!diff.text.hasSuffix("@@"))
    }

    /// Myers is quadratic on two texts that share nothing, so the guard is what
    /// keeps a diff of unrelated files from hanging the run.
    @Test
    func aDifferingRegionPastTheLineLimitIsRefused() {
        let old = (1...50).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...50).map { "new \($0)" }.joined(separator: "\n")
        #expect(throws: UnifiedDiff.Failure.tooLarge(lines: 50, limit: 10)) {
            try UnifiedDiff.between(old, new, fromPath: "f", toPath: "f", lineLimit: 10)
        }
    }

    /// The limit applies to what actually differs, not to file size — which is what
    /// makes editing a large file affordable.
    @Test
    func aLargeFileWithASmallChangeIsNotRefused() throws {
        let old = (1...5_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 2500\n", with: "line 2500 changed\n")
        let diff = try UnifiedDiff.between(
            old, new, fromPath: "f", toPath: "f", lineLimit: 50
        )
        #expect(diff.firstChangedLine == 2_500)
        #expect(diff.text.contains("+line 2500 changed"))
    }
}
