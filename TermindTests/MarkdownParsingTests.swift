import AppKit
import Foundation
import MarkdownParser
import Testing

@testable import Termind

@Suite
struct MarkdownParsingTests {
    @Test
    func blankLineSeparatedTextBecomesTwoParagraphs() {
        let blocks = TermindMarkdownParser.parse("first\n\nsecond")
        #expect(blocks.count == 2)
        #expect(paragraphText(blocks.first) == "first")
        #expect(paragraphText(blocks.last) == "second")
    }

    @Test
    func newlineInsideAParagraphSurvivesAsALineBreak() {
        let blocks = TermindMarkdownParser.parse("**Note:** this matters\nAnother line here")
        guard case .paragraph(let inlines)? = blocks.first else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }
        #expect(inlines.contains(.lineBreak))
        #expect(inlineText(inlines).contains("matters\nAnother"))
    }

    @Test
    func tableCarriesItsColumnAlignments() {
        let blocks = TermindMarkdownParser.parse(
            "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"
        )
        guard case .table(let alignments, let rows)? = blocks.first else {
            Issue.record("expected a table, got \(blocks)")
            return
        }
        #expect(alignments == [.left, .center, .right])
        #expect(rows.count == 2)
        #expect(rows[0].cells.map { inlineText($0.content) } == ["a", "b", "c"])
        #expect(rows[1].cells.map { inlineText($0.content) } == ["1", "2", "3"])
    }

    @Test
    func orderedAndNestedListsKeepTheirShape() {
        let blocks = TermindMarkdownParser.parse("3. first\n4. second\n   - nested")
        guard case .numberedList(_, let start, let items)? = blocks.first else {
            Issue.record("expected a numbered list, got \(blocks)")
            return
        }
        #expect(start == 3)
        #expect(items.count == 2)
        #expect(items[1].children.contains { block in
            guard case .bulletedList = block else { return false }
            return true
        })
    }

    @Test
    func taskListMarkersBecomeCheckboxes() {
        let blocks = TermindMarkdownParser.parse("- [x] done\n- [ ] todo")
        guard case .taskList(_, let items)? = blocks.first else {
            Issue.record("expected a task list, got \(blocks)")
            return
        }
        #expect(items.map(\.isCompleted) == [true, false])
        #expect(paragraphText(items[0].children.first) == "done")
        #expect(paragraphText(items[1].children.first) == "todo")
    }

    @Test
    func fencedCodeKeepsItsLanguageAndNewlines() {
        let blocks = TermindMarkdownParser.parse("```bash\nls -la\ncd /tmp\n```")
        guard case .codeBlock(let language, let code)? = blocks.first else {
            Issue.record("expected a code block, got \(blocks)")
            return
        }
        #expect(language == "bash")
        #expect(code.trimmingCharacters(in: .newlines) == "ls -la\ncd /tmp")
    }

    @Test
    func unterminatedFenceStillProducesACodeBlock() {
        let blocks = TermindMarkdownParser.parse("```bash\nls -la")
        guard case .codeBlock(let language, let code)? = blocks.first else {
            Issue.record("expected a code block, got \(blocks)")
            return
        }
        #expect(language == "bash")
        #expect(code.trimmingCharacters(in: .newlines) == "ls -la")
    }

    @Test
    func onlyOpenableSchemesRemainLinks() {
        let allowed = linkedInline("[docs](https://example.com)")
        guard case .link(let destination, _)? = allowed else {
            Issue.record("expected an allowed link")
            return
        }
        #expect(destination == "https://example.com")

        for source in ["[click](javascript:alert(1))", "[open](file:///etc/passwd)"] {
            let inlines = paragraphInlines(TermindMarkdownParser.parse(source).first)
            #expect(!inlines.contains { inline in
                guard case .link = inline else { return false }
                return true
            })
            #expect(inlineText(inlines).contains(source.contains("click") ? "click" : "open"))
        }
    }

    @Test
    func imagesKeepAltTextButLoseRemoteSource() {
        let blocks = TermindMarkdownParser.parse(
            "![alt text](https://tracker.test/p.png)"
        )
        let inlines = paragraphInlines(blocks.first)
        #expect(inlineText(inlines) == "alt text")
        #expect(!String(describing: inlines).contains("tracker.test"))
    }

    @Test
    func headingsQuotesRulesAndMathKeepTheirShape() {
        guard case .heading(let level, let heading)? =
            TermindMarkdownParser.parse("## Title").first
        else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 2)
        #expect(inlineText(heading) == "Title")

        guard case .blockquote(let children)? =
            TermindMarkdownParser.parse("> quoted").first
        else {
            Issue.record("expected a block quote")
            return
        }
        #expect(paragraphText(children.first) == "quoted")

        let ruleBlocks = TermindMarkdownParser.parse("above\n\n---\n\nbelow")
        #expect(ruleBlocks.count == 3)
        guard case .thematicBreak = ruleBlocks[1] else {
            Issue.record("expected a thematic break")
            return
        }

        let math = paragraphInlines(TermindMarkdownParser.parse("$x^2$").first)
        #expect(math.contains { inline in
            guard case .math(let content, _) = inline else { return false }
            return content == "x^2"
        })
    }

    @Test
    func assistantShellFencesBecomeActionSegments() {
        let blocks = TermindMarkdownParser.parse(
            "before\n\n```bash\necho ok\n```\n\nafter"
        )
        let segments = TermindMarkdownParser.segments(
            from: blocks,
            allowsShellActions: true
        )
        #expect(segments.count == 3)
        #expect(segments[1] == .shell(language: "bash", command: "echo ok"))

        let userSegments = TermindMarkdownParser.segments(
            from: blocks,
            allowsShellActions: false
        )
        #expect(userSegments.count == 1)
        guard case .markdown(let userBlocks) = userSegments[0] else {
            Issue.record("user code should stay native Markdown")
            return
        }
        #expect(userBlocks.count == blocks.count)
        #expect(userBlocks.contains { block in
            guard case .codeBlock = block else { return false }
            return true
        })
    }

    @Test
    func shellFenceExtractedFromAListStillBecomesAnActionSegment() {
        let blocks = TermindMarkdownParser.parse("- inspect\n\n  ```zsh\n  pwd\n  ```")
        let segments = TermindMarkdownParser.segments(
            from: blocks,
            allowsShellActions: true
        )
        #expect(segments.contains { segment in
            guard case .shell(let language, let command) = segment else { return false }
            return language == "zsh" && command.trimmingCharacters(in: .whitespaces) == "pwd"
        })
    }

    @Test
    func plainTextExtractionProducesOneLine() {
        let title = TermindMarkdownParser.plainText("""
            **Checked both hosts.**

            - Compare the logs
            - Verify `sshd`
            """)
        #expect(title == "Checked both hosts. Compare the logs Verify sshd")
    }

    @MainActor
    @Test
    func transientToolTitleFlattensBlocksAndPreservesSafeInlineMarkdown() throws {
        let title = TermindMarkdownParser.singleLineAttributedText("""
            **Checked** *both* hosts and [`sshd`](https://example.com).

            - ~~old result~~
            - final result
            """)

        #expect(title.string == "Checked both hosts and sshd. old result final result")
        let checked = (title.string as NSString).range(of: "Checked")
        let both = (title.string as NSString).range(of: "both")
        let sshd = (title.string as NSString).range(of: "sshd")
        let old = (title.string as NSString).range(of: "old result")
        let checkedFont = try #require(title.attribute(.font, at: checked.location, effectiveRange: nil) as? NSFont)
        let bothFont = try #require(title.attribute(.font, at: both.location, effectiveRange: nil) as? NSFont)
        #expect(checkedFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(bothFont.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(title.attribute(.link, at: sshd.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        #expect(title.attribute(.strikethroughStyle, at: old.location, effectiveRange: nil) != nil)
    }

    @Test
    func emptySourceProducesNothing() {
        #expect(TermindMarkdownParser.parse("").isEmpty)
    }

    // MARK: - Soft-break guards

    @Test(arguments: [
        "```\nnot prose\nstill code\n```",
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "<output label=\"log\">\nfirst\nsecond\n</output>",
        "text\n# Heading",
        "text\n- list item",
        "text\n1. list item",
        "Title\n===",
        "text\n---",
        "text\n```",
    ])
    func hardeningLeavesStructuralLinesAlone(source: String) {
        #expect(!MarkdownSoftBreaks.hardened(source).contains("\\"))
    }

    @Test
    func hardeningAddsOneBreakBetweenTwoProseLines() {
        #expect(MarkdownSoftBreaks.hardened("first\nsecond") == "first\\\nsecond")
    }

    @Test
    func hardeningDoesNotDoubleUpOnAnExistingHardBreak() {
        #expect(
            MarkdownSoftBreaks.hardened("first\\\nsecond").filter { $0 == "\\" }.count == 1
        )
        #expect(!MarkdownSoftBreaks.hardened("first  \nsecond").contains("\\"))
    }

    private func paragraphText(_ block: MarkdownBlockNode?) -> String? {
        guard case .paragraph(let inlines)? = block else { return nil }
        return inlineText(inlines)
    }

    private func paragraphInlines(_ block: MarkdownBlockNode?) -> [MarkdownInlineNode] {
        guard case .paragraph(let inlines)? = block else { return [] }
        return inlines
    }

    private func linkedInline(_ source: String) -> MarkdownInlineNode? {
        paragraphInlines(TermindMarkdownParser.parse(source).first).first { inline in
            guard case .link = inline else { return false }
            return true
        }
    }

    private func inlineText(_ inlines: [MarkdownInlineNode]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let value), .code(let value), .html(let value), .math(let value, _):
                value
            case .softBreak:
                " "
            case .lineBreak:
                "\n"
            case .emphasis(let children), .strong(let children),
                 .strikethrough(let children), .link(_, let children),
                 .image(_, let children):
                inlineText(children)
            }
        }.joined()
    }
}
