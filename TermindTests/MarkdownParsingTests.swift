import Foundation
import Testing

@testable import Termind

@Suite
struct MarkdownParsingTests {

    // MARK: - The reported failure

    @Test
    func blankLineSeparatedTextBecomesTwoParagraphs() {
        let blocks = MarkdownDocumentParser.parse("first\n\nsecond")
        #expect(blocks.count == 2)
        #expect(paragraphText(blocks.first) == "first")
        #expect(paragraphText(blocks.last) == "second")
    }

    /// Foundation follows CommonMark and turns a single newline into an
    /// untagged space, which is indistinguishable from a typed one — so the
    /// choice is made on the source, before parsing.
    @Test
    func newlineInsideAParagraphSurvivesAsALineBreak() {
        let blocks = MarkdownDocumentParser.parse("**Note:** this matters\nAnother line here")
        #expect(blocks.count == 1)
        let text = paragraphText(blocks.first) ?? ""
        #expect(text.contains("\n"))
        #expect(!text.contains("matters Another"))
    }

    @Test
    func tableCarriesItsColumnAlignments() {
        let blocks = MarkdownDocumentParser.parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
        guard case .table(let table)? = blocks.first else {
            Issue.record("expected a table, got \(blocks)")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.header.map { $0.map(\.text).joined() } == ["a", "b", "c"])
        #expect(table.rows.count == 1)
        #expect(table.rows.first?.map { $0.map(\.text).joined() } == ["1", "2", "3"])
    }

    // MARK: - The premise the grouping algorithm rests on

    /// `MarkdownDocumentParser` reverses `components` to turn a run's intent
    /// stack into a root-to-leaf path. That reversal is only correct because
    /// Foundation orders them innermost-first, which is an observed fact about
    /// the framework rather than a guarantee we control.
    @Test
    func presentationIntentComponentsAreOrderedInnermostFirst() throws {
        let attributed = try AttributedString(
            markdown: "- item", options: .init(interpretedSyntax: .full)
        )
        let components = try #require(attributed.runs.first?.presentationIntent?.components)
        #expect(components.count == 3)

        guard case .paragraph = components[0].kind else {
            Issue.record("expected the paragraph innermost, got \(components[0].kind)")
            return
        }
        guard case .listItem = components[1].kind else {
            Issue.record("expected the list item next, got \(components[1].kind)")
            return
        }
        guard case .unorderedList = components[2].kind else {
            Issue.record("expected the list outermost, got \(components[2].kind)")
            return
        }
    }

    // MARK: - Lists

    @Test
    func orderedListKeepsTheNumberItStartedAt() {
        let blocks = MarkdownDocumentParser.parse("3. first\n4. second")
        guard case .list(let list)? = blocks.first else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        #expect(list.isOrdered)
        #expect(list.start == 3)
        #expect(list.items.count == 2)
    }

    @Test
    func nestedListIsABlockInsideItsItem() {
        let blocks = MarkdownDocumentParser.parse("1. first\n2. second\n   - nested")
        guard case .list(let outer)? = blocks.first else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        let second = outer.items[1]
        let nested = second.blocks.compactMap { block -> MarkdownList? in
            guard case .list(let list) = block else { return nil }
            return list
        }
        #expect(nested.count == 1)
        #expect(nested.first?.isOrdered == false)
        #expect(paragraphText(nested.first?.items.first?.blocks.first) == "nested")
    }

    /// Foundation does not parse GFM task syntax, so the marker arrives as
    /// literal text at the head of the item and has to be taken back off.
    @Test
    func taskListMarkersBecomeCheckboxes() {
        let blocks = MarkdownDocumentParser.parse("- [x] done\n- [ ] todo")
        guard case .list(let list)? = blocks.first else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        #expect(list.items.map(\.checkbox) == [true, false])
        #expect(paragraphText(list.items[0].blocks.first) == "done")
        #expect(paragraphText(list.items[1].blocks.first) == "todo")
    }

    // MARK: - Code

    @Test
    func fencedCodeKeepsItsLanguageAndItsNewlines() {
        let blocks = MarkdownDocumentParser.parse("```bash\nls -la\ncd /tmp\n```")
        guard case .codeBlock(let language, let code)? = blocks.first else {
            Issue.record("expected a code block, got \(blocks)")
            return
        }
        #expect(language == "bash")
        #expect(code == "ls -la\ncd /tmp")
    }

    /// The streaming case: every parse before the last one sees a fence that
    /// has been opened and not yet closed.
    @Test
    func unterminatedFenceStillProducesACodeBlock() {
        let blocks = MarkdownDocumentParser.parse("```bash\nls -la")
        guard case .codeBlock(let language, let code)? = blocks.first else {
            Issue.record("expected a code block, got \(blocks)")
            return
        }
        #expect(language == "bash")
        #expect(code == "ls -la")
    }

    // MARK: - Attachments

    /// `ConversationModel.composed(_:)` promises the transcript holds exactly
    /// what was uploaded. `*5` is the test: emphasis would eat it.
    @Test
    func composedAttachmentSurvivesVerbatim() {
        let source = """
            Why is disk full?

            <output label="nginx.log">
            [error] 1234#0: *5 open() failed
            disk usage: 99%
            </output>
            """
        let blocks = MarkdownDocumentParser.parse(source)
        #expect(blocks.count == 2)
        guard case .htmlBlock(let raw)? = blocks.last else {
            Issue.record("expected an HTML block, got \(blocks)")
            return
        }
        #expect(raw.contains("*5 open() failed"))
        #expect(raw.contains("disk usage: 99%"))

        let attachment = AttachmentBlock.parse(raw)
        #expect(attachment?.kind == .output)
        #expect(attachment?.label == "nginx.log")
        #expect(attachment?.content == "[error] 1234#0: *5 open() failed\ndisk usage: 99%")
    }

    @Test
    func htmlThatIsNotAnAttachmentIsLeftAsText() {
        let blocks = MarkdownDocumentParser.parse("<script>alert(1)</script>")
        guard case .htmlBlock(let raw)? = blocks.first else {
            Issue.record("expected an HTML block, got \(blocks)")
            return
        }
        #expect(raw.contains("<script>"))
        #expect(AttachmentBlock.parse(raw) == nil)
    }

    // MARK: - Links and images

    @Test
    func onlyOpenableSchemesBecomeLinks() {
        let allowed = linkedInline("[docs](https://example.com)")
        #expect(allowed?.link?.absoluteString == "https://example.com")
        #expect(allowed?.rejectedLinkTarget == nil)
    }

    @Test
    func refusedSchemesKeepTheirLabelAsProse() {
        for source in ["[click](javascript:alert(1))", "[open](file:///etc/passwd)"] {
            let inline = linkedInline(source)
            #expect(inline?.link == nil, "\(source) should not be openable")
            #expect(inline?.rejectedLinkTarget != nil, "\(source) should report its target")
        }
    }

    /// Foundation drops the URL and keeps the alt text, which closes the
    /// channel where a model-chosen image URL discloses the reader's IP and
    /// reading time the moment a message renders.
    @Test
    func imagesLoseTheirURL() {
        let blocks = MarkdownDocumentParser.parse("![alt text](https://tracker.test/p.png)")
        let rendered = blocks.compactMap(paragraphText).joined()
        #expect(rendered.contains("alt text"))
        #expect(!rendered.contains("tracker.test"))
    }

    // MARK: - Other blocks

    @Test
    func thematicBreakDropsItsPlaceholderGlyph() {
        let blocks = MarkdownDocumentParser.parse("above\n\n---\n\nbelow")
        #expect(blocks.count == 3)
        guard case .thematicBreak = blocks[1] else {
            Issue.record("expected a thematic break, got \(blocks[1])")
            return
        }
    }

    @Test
    func headingAndQuoteKeepTheirShape() {
        guard case .heading(let level, let inlines)? = MarkdownDocumentParser.parse("## Title").first
        else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 2)
        #expect(inlines.map(\.text).joined() == "Title")

        guard case .blockQuote(let children)? = MarkdownDocumentParser.parse("> quoted").first else {
            Issue.record("expected a block quote")
            return
        }
        #expect(paragraphText(children.first) == "quoted")
    }

    @Test
    func emptySourceProducesNothing() {
        #expect(MarkdownDocumentParser.parse("").isEmpty)
    }

    // MARK: - Soft-break guards

    /// Each of these marks a place where appending a hard-break backslash would
    /// corrupt the source rather than break a line.
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
        #expect(MarkdownSoftBreaks.hardened("first\\\nsecond").filter { $0 == "\\" }.count == 1)
        #expect(!MarkdownSoftBreaks.hardened("first  \nsecond").contains("\\"))
    }

    @Test
    func hardeningLeavesASingleLineUntouched() {
        #expect(MarkdownSoftBreaks.hardened("just one line") == "just one line")
    }

    // MARK: - Helpers

    private func paragraphText(_ block: MarkdownBlock?) -> String? {
        guard case .paragraph(let inlines)? = block else { return nil }
        return inlines.map(\.text).joined()
    }

    /// The one inline in `source` that carried a link, allowed or refused.
    private func linkedInline(_ source: String) -> MarkdownInline? {
        guard case .paragraph(let inlines)? = MarkdownDocumentParser.parse(source).first else {
            return nil
        }
        return inlines.first { $0.link != nil || $0.rejectedLinkTarget != nil }
    }
}
