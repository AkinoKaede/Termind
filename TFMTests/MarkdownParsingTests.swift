import AppKit
import Foundation
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite
struct MarkdownParsingTests {
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

}
