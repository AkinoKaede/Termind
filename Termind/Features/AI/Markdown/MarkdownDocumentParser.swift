import Foundation

/// Turns Markdown source into blocks a view can actually draw.
///
/// The parsing is Foundation's — `AttributedString(markdown:)` is cmark-gfm
/// underneath and gets tables, column alignments, nested lists, fenced code and
/// inline styles right. What it does *not* do is render: it records block
/// structure as `presentationIntent` attribute runs and writes no newline
/// between blocks, and SwiftUI's `Text` ignores that attribute entirely. So a
/// table arrives as the four characters `abcd` with the structure hanging off
/// them, and everything a reader would recognise is discarded at draw time.
///
/// This type closes that gap. It takes the flat run list Foundation produces
/// and rebuilds the nesting SwiftUI's view tree needs — nothing is re-parsed.
nonisolated enum MarkdownDocumentParser {

    /// Schemes a rendered link may carry.
    ///
    /// Model output is untrusted and tool results are fed back into it, so a
    /// reply can contain `[click here](file:///…)` or a URL that hands a custom
    /// handler its argument. Anything outside this set keeps its label as prose
    /// and surfaces its target on hover instead.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    private static let parsingOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .full,
        // A message is re-parsed on every burst of streamed tokens, so most
        // parses run against a half-written document. Failing the whole thing
        // would blank the reply mid-sentence.
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }

        guard
            let attributed = try? AttributedString(
                markdown: MarkdownSoftBreaks.hardened(text),
                options: parsingOptions
            )
        else {
            // Never swallow the model's reply because its Markdown was strange.
            return [.paragraph([MarkdownInline(text: text)])]
        }

        var stack: [OpenBlock] = []
        var roots: [MarkdownBlock] = []

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            // `components` is ordered innermost-first, so this reversal is what
            // turns a run's intent stack into a root-to-leaf path. The order is
            // load-bearing and is locked by a test.
            let path = Array(run.presentationIntent?.components.reversed() ?? [])

            let shared = sharedPrefixLength(stack, path)
            while stack.count > shared { closeTop(&stack, into: &roots) }
            for component in path[shared...] { stack.append(OpenBlock(component)) }

            guard !text.isEmpty else { continue }

            guard let innermost = stack.indices.last else {
                appendUnparented(text, intent: run.inlinePresentationIntent, into: &roots)
                continue
            }
            switch stack[innermost].role {
            case .codeBlock:
                stack[innermost].code += text
            case .thematicBreak:
                // Foundation gives a horizontal rule a placeholder glyph
                // (U+2E3B). The rule is the block; the character is noise.
                break
            default:
                stack[innermost].inlines.append(
                    inline(text, intent: run.inlinePresentationIntent, link: run.link)
                )
            }
        }

        while !stack.isEmpty { closeTop(&stack, into: &roots) }
        return roots
    }

    // MARK: - Stack

    /// A block that has been entered but not yet finished.
    ///
    /// One struct for every role rather than an enum with associated values:
    /// the accumulators are mutated in place through `stack[i].field`, which an
    /// enum payload cannot be. Only the fields a given role uses are ever read.
    private struct OpenBlock {
        enum Role {
            case paragraph
            case heading(Int)
            case codeBlock(String?)
            case blockQuote
            case list(ordered: Bool)
            case listItem(ordinal: Int)
            case table([MarkdownTable.Alignment])
            case tableRow(isHeader: Bool)
            case tableCell
            case thematicBreak
            case unknown
        }

        let identity: Int
        let role: Role

        var inlines: [MarkdownInline] = []
        var blocks: [MarkdownBlock] = []
        var code = ""
        var cells: [[MarkdownInline]] = []
        var rows: [[[MarkdownInline]]] = []
        var header: [[MarkdownInline]] = []
        var items: [MarkdownList.Item] = []
        var listStart: Int?

        init(_ component: PresentationIntent.IntentType) {
            identity = component.identity
            switch component.kind {
            case .paragraph: role = .paragraph
            case .header(let level): role = .heading(level)
            case .codeBlock(let languageHint): role = .codeBlock(languageHint)
            case .blockQuote: role = .blockQuote
            case .orderedList: role = .list(ordered: true)
            case .unorderedList: role = .list(ordered: false)
            case .listItem(let ordinal): role = .listItem(ordinal: ordinal)
            case .table(let columns): role = .table(columns.map(MarkdownDocumentParser.alignment))
            case .tableHeaderRow: role = .tableRow(isHeader: true)
            case .tableRow: role = .tableRow(isHeader: false)
            case .tableCell: role = .tableCell
            case .thematicBreak: role = .thematicBreak
            @unknown default: role = .unknown
            }
        }
    }

    private static func sharedPrefixLength(
        _ stack: [OpenBlock], _ path: [PresentationIntent.IntentType]
    ) -> Int {
        var shared = 0
        while shared < stack.count, shared < path.count,
            stack[shared].identity == path[shared].identity
        {
            shared += 1
        }
        return shared
    }

    /// Finishes the innermost block and folds it into whatever contains it —
    /// the block below on the stack, or the document.
    private static func closeTop(_ stack: inout [OpenBlock], into roots: inout [MarkdownBlock]) {
        let closed = stack.removeLast()
        let parent = stack.indices.last

        switch closed.role {
        case .tableCell:
            guard let parent else { return }
            stack[parent].cells.append(closed.inlines)

        case .tableRow(let isHeader):
            guard let parent else { return }
            if isHeader {
                stack[parent].header = closed.cells
            } else {
                stack[parent].rows.append(closed.cells)
            }

        case .listItem(let ordinal):
            guard let parent else { return }
            var blocks = closed.blocks
            let checkbox = takeCheckbox(from: &blocks)
            stack[parent].items.append(MarkdownList.Item(checkbox: checkbox, blocks: blocks))
            // Whatever the first item was numbered is where the list starts, so
            // `3. 4. 5.` is not silently renumbered from one.
            if stack[parent].listStart == nil { stack[parent].listStart = ordinal }

        default:
            guard let block = block(from: closed) else { return }
            if let parent {
                stack[parent].blocks.append(block)
            } else {
                roots.append(block)
            }
        }
    }

    private static func block(from open: OpenBlock) -> MarkdownBlock? {
        switch open.role {
        case .paragraph, .unknown:
            return open.inlines.isEmpty ? nil : .paragraph(open.inlines)
        case .heading(let level):
            return open.inlines.isEmpty ? nil : .heading(level: level, open.inlines)
        case .codeBlock(let language):
            var code = open.code
            // The fence's own closing newline is structure, not content.
            if code.hasSuffix("\n") { code.removeLast() }
            let hint = language?.trimmingCharacters(in: .whitespaces)
            return .codeBlock(language: (hint?.isEmpty ?? true) ? nil : hint, code: code)
        case .blockQuote:
            return open.blocks.isEmpty ? nil : .blockQuote(open.blocks)
        case .list(let ordered):
            guard !open.items.isEmpty else { return nil }
            return .list(
                MarkdownList(isOrdered: ordered, start: open.listStart ?? 1, items: open.items)
            )
        case .table(let alignments):
            return .table(
                MarkdownTable(alignments: alignments, header: open.header, rows: open.rows)
            )
        case .thematicBreak:
            return .thematicBreak
        case .listItem, .tableRow, .tableCell:
            return nil  // Folded into their container by `closeTop`.
        }
    }

    // MARK: - Runs with no block of their own

    /// A run can carry no `presentationIntent` at all, which in practice means
    /// raw HTML — and in this app that is how a composed attachment arrives.
    /// Consecutive runs are merged so one `<output>…</output>` stays one block.
    private static func appendUnparented(
        _ text: String, intent: InlinePresentationIntent?, into roots: inout [MarkdownBlock]
    ) {
        guard intent?.contains(.blockHTML) == true || intent?.contains(.inlineHTML) == true else {
            roots.append(.paragraph([MarkdownInline(text: text)]))
            return
        }
        if case .htmlBlock(let existing)? = roots.last {
            roots[roots.count - 1] = .htmlBlock(existing + text)
        } else {
            roots.append(.htmlBlock(text))
        }
    }

    // MARK: - Inline

    private static func inline(
        _ text: String, intent: InlinePresentationIntent?, link: URL?
    ) -> MarkdownInline {
        var style: MarkdownInline.Style = []
        if let intent {
            if intent.contains(.emphasized) { style.insert(.emphasis) }
            if intent.contains(.stronglyEmphasized) { style.insert(.strong) }
            if intent.contains(.code) { style.insert(.code) }
            if intent.contains(.strikethrough) { style.insert(.strikethrough) }
        }

        var result = MarkdownInline(text: text, style: style)
        guard let link else { return result }
        if allowedLinkSchemes.contains(link.scheme?.lowercased() ?? "") {
            result.link = link
        } else {
            result.rejectedLinkTarget = link.absoluteString
        }
        return result
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownTable.Alignment
    {
        switch column.alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }

    // MARK: - Task lists

    /// Foundation does not parse GFM task syntax, so `- [x] done` reaches us as
    /// a list item whose first paragraph literally starts with `[x] `. Strip it
    /// back off and report what it said.
    private static func takeCheckbox(from blocks: inout [MarkdownBlock]) -> Bool? {
        guard case .paragraph(var inlines)? = blocks.first,
            let first = inlines.first,
            first.style.isEmpty, first.link == nil
        else { return nil }

        let checked: Bool
        if first.text.hasPrefix("[x] ") || first.text.hasPrefix("[X] ") {
            checked = true
        } else if first.text.hasPrefix("[ ] ") {
            checked = false
        } else {
            return nil
        }

        var stripped = first
        stripped.text = String(first.text.dropFirst(4))
        inlines[0] = stripped
        blocks[0] = .paragraph(inlines)
        return checked
    }
}
