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
        MarkdownView(text, theme: theme).frame(maxWidth: .infinity, alignment: .leading)
    }
}
