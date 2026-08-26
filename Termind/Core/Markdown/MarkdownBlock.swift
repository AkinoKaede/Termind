import Foundation

/// One run of inline text carrying the styles that apply to all of it.
///
/// Deliberately not an `AttributedString`: the SwiftUI attribute scope that
/// paints these — `.font`, `.backgroundColor`, `.link` — lives in SwiftUI, and
/// `Core` must not import it. The view builds the attributed string from these
/// values, which also keeps the parser testable without a rendering pass.
nonisolated struct MarkdownInline: Hashable, Sendable {
    nonisolated struct Style: OptionSet, Hashable, Sendable {
        let rawValue: Int

        static let emphasis = Style(rawValue: 1 << 0)
        static let strong = Style(rawValue: 1 << 1)
        static let code = Style(rawValue: 1 << 2)
        static let strikethrough = Style(rawValue: 1 << 3)
    }

    var text: String
    var style: Style = []
    /// Set only for schemes the renderer will actually open — see
    /// `MarkdownDocumentParser.allowedLinkSchemes`.
    var link: URL?
    /// The destination of a link whose scheme was refused. The view shows the
    /// label as plain text and reveals this on hover, so a `[click here](…)`
    /// pointing at `file://` or a custom handler cannot masquerade as prose.
    var rejectedLinkTarget: String?
}

nonisolated struct MarkdownList: Hashable, Sendable {
    nonisolated struct Item: Hashable, Sendable {
        /// `nil` for an ordinary bullet. GFM task syntax is not parsed by
        /// Foundation, so this is recovered from the leading `[x] ` / `[ ] `
        /// that survives into the item's first paragraph.
        var checkbox: Bool?
        var blocks: [MarkdownBlock] = []
    }

    var isOrdered: Bool
    /// The ordinal the list actually starts at, so `3. 4. 5.` is not renumbered
    /// to `1. 2. 3.`.
    var start: Int = 1
    var items: [Item] = []
}

nonisolated struct MarkdownTable: Hashable, Sendable {
    nonisolated enum Alignment: Hashable, Sendable {
        case leading, center, trailing
    }

    /// One entry per column. A GFM delimiter row may leave a column
    /// unspecified, which becomes `.leading`.
    var alignments: [Alignment] = []
    var header: [[MarkdownInline]] = []
    var rows: [[[MarkdownInline]]] = []
}

/// One block of rendered Markdown.
///
/// Recursion runs through arrays — a list item and a block quote both hold
/// `[MarkdownBlock]` — so the enum needs no `indirect`.
///
/// There are deliberately no identifiers on any of this. `ForEach` keys on
/// array offset instead, because a streaming message is re-parsed from scratch
/// on every burst of tokens: freshly minted `UUID`s would destroy view identity
/// several times a second and take text selection and animation with them.
nonisolated enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    case codeBlock(language: String?, code: String)
    case list(MarkdownList)
    case table(MarkdownTable)
    case blockQuote([MarkdownBlock])
    /// Raw HTML, kept verbatim and never interpreted.
    ///
    /// This is also how a composed attachment arrives — `ConversationModel`
    /// wraps chip payloads in `<output label="…">…</output>`, and Foundation
    /// hands the whole thing back as one untouched HTML block. Recognising that
    /// grammar is the view layer's job: the tag vocabulary belongs to
    /// `ContextChip.Kind`, which `Core` must not depend on.
    case htmlBlock(String)
    case thematicBreak
}
