import SwiftUI

/// Parsed blocks for text that has stopped changing.
///
/// Settled messages are the overwhelming majority of a transcript and their
/// text never changes again, so parsing belongs behind a cache rather than in a
/// `body` that a `LazyVStack` re-evaluates on every scroll frame.
///
/// Main-actor isolated by the project's default, which is what makes an
/// unsynchronised dictionary safe here.
enum MarkdownParseCache {
    private static var storage: [String: [MarkdownBlock]] = [:]
    private static var insertionOrder: [String] = []
    /// Enough for any transcript a reader can see at once, and bounded so a
    /// long conversation cannot retain every message it ever showed.
    private static let limit = 64

    static func blocks(for text: String) -> [MarkdownBlock] {
        if let cached = storage[text] { return cached }
        let parsed = MarkdownDocumentParser.parse(text)
        storage[text] = parsed
        insertionOrder.append(text)
        if insertionOrder.count > limit {
            storage.removeValue(forKey: insertionOrder.removeFirst())
        }
        return parsed
    }
}

/// Renders Markdown source.
///
/// Two paths, because a message has two lives. Settled text is parsed
/// synchronously through `MarkdownParseCache`, so a row scrolling back into
/// view draws its blocks on the first frame instead of flashing empty. Text
/// still streaming is parsed on a debounce: `.task(id:)` cancels the previous
/// parse whenever the text changes, so a reply arriving forty tokens a second
/// is parsed when it pauses rather than forty times — which for a growing
/// message would be quadratic. Streamed strings are deliberately not cached;
/// there are hundreds of them and every one is garbage a keystroke later.
///
/// Parsing stays on the main actor: at chat-message sizes it is well under a
/// millisecond, and a detached hop would cost more than it saves.
/// `MarkdownDocumentParser` is `nonisolated` and returns only `Sendable`
/// values, so moving it off is a one-line change if that stops being true.
struct MarkdownView: View {
    let text: String
    var isStreaming = false
    /// Assistant output may offer to run the shell it wrote; text the user
    /// typed may not.
    var isAssistant = true
    var isCompact = false

    @State private var streamedBlocks: [MarkdownBlock] = []

    private var blocks: [MarkdownBlock] {
        isStreaming ? streamedBlocks : MarkdownParseCache.blocks(for: text)
    }

    var body: some View {
        MarkdownBlockListView(blocks: blocks, isAssistant: isAssistant, isCompact: isCompact)
            .task(id: text) {
                guard isStreaming else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                streamedBlocks = MarkdownDocumentParser.parse(text)
            }
    }
}

private struct MarkdownFillsWidthKey: EnvironmentKey {
    nonisolated static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether Markdown blocks claim all the width they are offered.
    ///
    /// True on the page, where assistant prose *is* the column. False inside a
    /// user bubble, which has to shrink to fit a three-word question rather
    /// than stretch it across the whole transcript.
    ///
    /// An environment value rather than a parameter because the blocks that
    /// need to know are several levels down and not all of them are reached
    /// through `MarkdownBlockListView` — code blocks and attachment rows are
    /// their own types.
    var markdownFillsWidth: Bool {
        get { self[MarkdownFillsWidthKey.self] }
        set { self[MarkdownFillsWidthKey.self] = newValue }
    }
}

extension View {
    /// `nil` rather than a branch: a conditional `.frame` would change view
    /// identity between the two cases and throw away scroll and selection
    /// state, while a nil `maxWidth` simply imposes no constraint.
    func markdownWidth(fills: Bool, alignment: Alignment = .leading) -> some View {
        frame(maxWidth: fills ? .infinity : nil, alignment: alignment)
    }
}

struct MarkdownBlockListView: View {
    let blocks: [MarkdownBlock]
    var isAssistant = true
    var isCompact = false

    @Environment(\.markdownFillsWidth) private var fillsWidth

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Chat.blockSpacing) {
            // Offset identity, not a stored id. A streaming message is re-parsed
            // from scratch, so any minted identifier would change every burst.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, isAssistant: isAssistant, isCompact: isCompact)
            }
        }
        // Set once on the container so every block inherits it and only
        // headings and code have to say otherwise.
        .font(MarkdownTypography.body)
        .markdownWidth(fills: fillsWidth)
    }
}

/// The transcript's type scale, in one place because it has to stay monotonic:
/// `.subheadline` is *smaller* than `.body` on macOS, so a heading ladder built
/// by eye ends up with an h3 that reads as a caption.
enum MarkdownTypography {
    /// Reading size for prose, tables and list content.
    static let body = Font.body
    static let monospaced = Font.system(.body, design: .monospaced)

    static func heading(level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: body.weight(.semibold)
        }
    }
}

// MARK: - One block

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let isAssistant: Bool
    let isCompact: Bool

    @Environment(\.markdownFillsWidth) private var fillsWidth

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            MarkdownParagraphView(inlines: inlines)

        case .heading(let level, let inlines):
            MarkdownParagraphView(inlines: inlines)
                .font(MarkdownTypography.heading(level: level))
                .padding(.top, Metrics.Space.xs)

        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language, code: code, isActionable: isAssistant)

        case .list(let list):
            MarkdownListView(list: list, isAssistant: isAssistant, isCompact: isCompact)

        case .table(let table):
            MarkdownTableView(table: table)

        case .blockQuote(let children):
            HStack(alignment: .top, spacing: Metrics.Space.m) {
                RoundedRectangle(cornerRadius: Metrics.Chat.rule / 2)
                    .fill(.quaternary)
                    .frame(width: Metrics.Chat.rule)
                MarkdownBlockListView(
                    blocks: children, isAssistant: isAssistant, isCompact: isCompact
                )
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        case .htmlBlock(let raw):
            if let attachment = AttachmentBlock.parse(raw) {
                MarkdownAttachmentView(attachment: attachment)
            } else {
                Text(raw)
                    .font(MarkdownTypography.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .markdownWidth(fills: fillsWidth)
            }

        case .thematicBreak:
            Divider().opacity(0.5)
        }
    }
}

// MARK: - Paragraph

private struct MarkdownParagraphView: View {
    let inlines: [MarkdownInline]

    @Environment(\.markdownFillsWidth) private var fillsWidth

    var body: some View {
        Text(MarkdownInlineText.attributed(inlines))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .markdownWidth(fills: fillsWidth)
            .help(Text(blockedLinkWarning ?? ""))
    }

    /// A link whose scheme was refused keeps its label as ordinary prose, which
    /// is safe but silent. Naming the destinations on hover is what turns
    /// "click here" back into something a reader can judge.
    private var blockedLinkWarning: String? {
        let blocked = inlines.compactMap(\.rejectedLinkTarget)
        guard !blocked.isEmpty else { return nil }
        return String(localized: "Blocked link: \(blocked.joined(separator: ", "))")
    }
}

/// Builds the attributed string a `Text` draws.
///
/// Styles travel as `inlinePresentationIntent` rather than as concrete fonts,
/// because SwiftUI resolves that against whatever font the environment supplies
/// — so a bold run inside a heading stays heading-sized. Setting `.font`
/// directly would pin every span to one size and break inheritance.
enum MarkdownInlineText {
    static func attributed(_ inlines: [MarkdownInline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            var piece = AttributedString(inline.text)

            var intent: InlinePresentationIntent = []
            if inline.style.contains(.emphasis) { intent.insert(.emphasized) }
            if inline.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
            if inline.style.contains(.code) { intent.insert(.code) }
            if inline.style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }

            if inline.style.contains(.code) {
                piece.backgroundColor = .secondary.opacity(0.15)
            }
            if let link = inline.link {
                piece.link = link
                piece.underlineStyle = .single
            }

            result.append(piece)
        }
        return result
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let list: MarkdownList
    let isAssistant: Bool
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.xs) {
                    marker(at: index, item: item)
                        // A fixed column is what makes a wrapped second line sit
                        // under the text instead of under the bullet — and what
                        // gives a nested list its indent for free, since the
                        // nested blocks start after this column.
                        .frame(width: Metrics.Chat.markerColumn, alignment: .trailing)
                    MarkdownBlockListView(
                        blocks: item.blocks, isAssistant: isAssistant, isCompact: isCompact
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func marker(at index: Int, item: MarkdownList.Item) -> some View {
        if let checkbox = item.checkbox {
            // Rendered, not interactive: this is a transcript of what was said,
            // not a to-do list the reader owns.
            Image(systemName: checkbox ? "checkmark.square.fill" : "square")
                .font(.caption)
                .foregroundStyle(checkbox ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } else if list.isOrdered {
            Text("\(list.start + index).")
                .font(MarkdownTypography.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .font(MarkdownTypography.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable

    private var columnCount: Int {
        max(table.alignments.count, table.header.count, table.rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        // No horizontal `ScrollView` around this, deliberately. A scroll view
        // proposes unbounded width to its content, and the header `Divider` is
        // greedy in width — so the grid grew to that unbounded width and every
        // centered or trailing column was aligned to an edge no one can reach.
        // The table renders blank. Letting the grid negotiate the real width and
        // wrapping the cells is both correct and easier to read than a
        // horizontally scrolling region nested inside a vertical one.
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !table.header.isEmpty {
                GridRow {
                    ForEach(columns, id: \.self) { column in
                        // Set on the header cell, which is what governs the
                        // whole column for the rows beneath it.
                        cell(table.header[safe: column])
                            .font(MarkdownTypography.body.weight(.semibold))
                            .gridColumnAlignment(alignment(for: column))
                    }
                }
                Divider()
            }
            // No zebra striping. A per-cell background only paints the cell's
            // own area, and a centered column's cell is narrower than its
            // column — so the stripe came out broken into pieces. The header
            // rule is enough separation for a table this size.
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(columns, id: \.self) { column in
                        cell(row[safe: column])
                    }
                }
            }
        }
        .padding(.vertical, Metrics.Chat.tableCellPadding)
        .background(.quaternary.opacity(0.12), in: .rect(cornerRadius: Metrics.Radius.small))
    }

    /// `ForEach` over a live `Range<Int>` is the dynamic-data case SwiftUI warns
    /// about, and a ragged table changes this count between renders.
    private var columns: [Int] { Array(0..<columnCount) }

    private func cell(_ inlines: [MarkdownInline]?) -> some View {
        Text(MarkdownInlineText.attributed(inlines ?? []))
            .textSelection(.enabled)
            // Wrap rather than truncate: with no scroll to escape into, a
            // narrow column has to grow downwards or the cell is unreadable.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Chat.tableCellPadding)
    }

    private func alignment(for column: Int) -> HorizontalAlignment {
        switch table.alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension Array {
    /// Tables from a model are frequently ragged — a row with one cell missing
    /// is common enough that indexing has to tolerate it rather than trap.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
