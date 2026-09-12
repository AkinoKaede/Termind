import MarkdownParser
import MarkdownView
import SwiftUI

/// Both hosts use the same Markdown engine; their composers remain platform-owned.
public struct AssistantMessageBody: View {
    private let text: String
    private let theme: MarkdownTheme

    public init(_ text: String, theme: MarkdownTheme = .default) {
        self.text = text
        self.theme = theme
    }

    public var body: some View {
        let parsed = MarkdownParser().parse(MarkdownSoftBreaks.hardened(text))
        let content = MarkdownContent(
            blocks: TermindMarkdownParser.sanitize(parsed.document),
            rendered: parsed.renderedContent(theme: theme),
            highlightMaps: parsed.highlightMaps(theme: theme),
            locale: .autoupdatingCurrent
        )
        MarkdownView(content, theme: theme).frame(maxWidth: .infinity, alignment: .leading)
    }
}
