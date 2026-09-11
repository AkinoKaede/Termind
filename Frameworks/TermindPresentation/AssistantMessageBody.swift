import MarkdownView
import SwiftUI

/// Both hosts use the same Markdown engine; their composers remain platform-owned.
public struct AssistantMessageBody: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { MarkdownView(text).frame(maxWidth: .infinity, alignment: .leading) }
}
