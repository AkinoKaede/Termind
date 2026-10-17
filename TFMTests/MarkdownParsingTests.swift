import AppKit
import Foundation
import MarkdownParser
import TermindApplication
import TermindPresentation
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
        #expect(
            items[1].children.contains { block in
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

    @Test(arguments: [
        ("```bash\nls -la\ncd /tmp\n```", "ls -la\ncd /tmp"),
        ("```bash\nls -la", "ls -la"),
    ])
    func fencedCodeKeepsItsLanguageAndNewlines(markdown: String, expectedCode: String) {
        let blocks = TermindMarkdownParser.parse(markdown)
        guard case .codeBlock(let language, let code)? = blocks.first else {
            Issue.record("expected a code block, got \(blocks)")
            return
        }
        #expect(language == "bash")
        #expect(code.trimmingCharacters(in: .newlines) == expectedCode)
    }

    @Test(arguments: ["https://example.com", "file:///tmp/example.txt", "ssh://example.com", "custom:document"])
    @MainActor
    func renderedLinksKeepTheirOriginalScheme(destination: String) throws {
        let document = TermindMarkdownRenderedDocument(
            source: "[open](\(destination))",
            theme: TermindMarkdownTheme.make(tone: .primary)
        )
        let inline = try #require(paragraphInlines(document.content.blocks.first).first)
        guard case .link(let renderedDestination, let children) = inline else {
            Issue.record("expected the original link")
            return
        }
        #expect(renderedDestination == destination)
        #expect(inlineText(children) == "open")
    }

    @Test
    @MainActor
    func renderedImagesKeepTheirSourceAndAltText() throws {
        let document = TermindMarkdownRenderedDocument(
            source: "![alt text](https://example.com/p.png)",
            theme: TermindMarkdownTheme.make(tone: .primary)
        )
        let inline = try #require(paragraphInlines(document.content.blocks.first).first)
        guard case .image(let source, let children) = inline else {
            Issue.record("expected an image node")
            return
        }
        #expect(source == "https://example.com/p.png")
        #expect(inlineText(children) == "alt text")
    }

    @Test
    func headingsQuotesRulesAndMathKeepTheirShape() {
        guard
            case .heading(let level, let heading)? =
                TermindMarkdownParser.parse("## Title").first
        else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 2)
        #expect(inlineText(heading) == "Title")

        guard
            case .blockquote(let children)? =
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
        #expect(
            math.contains { inline in
                guard case .math(let content, _) = inline else { return false }
                return content == "x^2"
            })
    }

    @Test
    @MainActor
    func renderedDocumentKeepsShellFencesAndTablesInOrder() throws {
        let document = TermindMarkdownRenderedDocument(
            source: """
                Before the blocks.

                ```bash
                echo ok
                ```

                | Name | Value |
                | --- | --- |
                | result | ready |

                After the blocks.
                """,
            theme: TermindMarkdownTheme.make(tone: .primary)
        )
        let blocks = document.content.blocks
        try #require(blocks.count == 4)
        #expect(paragraphText(blocks.first) == "Before the blocks.")
        guard case .codeBlock(let language, let code) = blocks[1],
            case .table = blocks[2]
        else {
            Issue.record("expected shell code and a table in the same Markdown document")
            return
        }
        #expect(language == "bash")
        #expect(code == "echo ok\n")
        #expect(paragraphText(blocks.last) == "After the blocks.")
    }

    @Test
    func plainTextExtractionProducesOneLine() {
        let title = TermindMarkdownParser.plainText(
            """
            **Checked both hosts.**

            - Compare the logs
            - Verify `sshd`
            """)
        #expect(title == "Checked both hosts. Compare the logs Verify sshd")
    }

    @MainActor
    @Test
    func transientToolTitleFlattensBlocksAndPreservesInlineMarkdown() throws {
        let title = TermindMarkdownParser.singleLineAttributedText(
            """
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
        #expect(
            title.attribute(.link, at: sshd.location, effectiveRange: nil) as? URL == URL(string: "https://example.com")
        )
        #expect(title.attribute(.strikethroughStyle, at: old.location, effectiveRange: nil) != nil)
    }

    @Test
    func emptySourceProducesNothing() {
        #expect(TermindMarkdownParser.parse("").isEmpty)
    }

    @Test(arguments: [
        "**Note:** this matters\nAnother line here",
        "first\\\nsecond",
        "first  \nsecond",
    ])
    func paragraphLineBreaksFollowUpstreamSoftAndHardRules(source: String) {
        let inlines = paragraphInlines(TermindMarkdownParser.parse(source).first)
        if source.hasPrefix("**Note:**") {
            #expect(inlines.contains(.softBreak))
            #expect(!inlines.contains(.lineBreak))
            #expect(inlineText(inlines).contains("matters Another"))
        } else {
            #expect(inlines.contains(.lineBreak))
            #expect(inlineText(inlines) == "first\nsecond")
        }
    }

    @MainActor
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func suggestedCommandKeepsLiteralCodeAndLocalizesTheUpstreamHeader(language: String) throws {
        let command = "printf '%s\\n' '```'\ncat <<'EOF'\n# literal heading\nEOF"
        let content = SuggestedCommandCodeBlock.content(command, locale: Locale(identifier: language))
        try #require(content.blocks.count == 1)
        guard case .codeBlock(let title, let code) = content.blocks[0] else {
            Issue.record("expected a single code block")
            return
        }
        let titles = ["en": "Suggested Command", "zh-Hans": "建议的命令", "zh-Hant": "建議的指令"]
        #expect(title == titles[language])
        #expect(code == command)
    }

    private func paragraphText(_ block: MarkdownBlockNode?) -> String? {
        guard case .paragraph(let inlines)? = block else { return nil }
        return inlineText(inlines)
    }

    private func paragraphInlines(_ block: MarkdownBlockNode?) -> [MarkdownInlineNode] {
        guard case .paragraph(let inlines)? = block else { return [] }
        return inlines
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
