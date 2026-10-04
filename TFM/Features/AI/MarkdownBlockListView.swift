import AppKit
import MarkdownParser
import MarkdownView
import SwiftUI
import TermindPresentation

enum TermindMarkdownTone: Hashable {
    case primary
    case secondary
}

// MARK: - Transcript titles

extension TermindMarkdownParser {
    /// A one-line AppKit projection for transient tool titles. It preserves
    /// inline emphasis/code/strikethrough/links and flattens block structure
    /// without allowing it to change the disclosure header's height.
    @MainActor
    static func singleLineAttributedText(
        _ source: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        color: NSColor = .secondaryLabelColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        func append(_ value: String, attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        func separator() {
            guard result.length > 0,
                !result.string.hasSuffix(" ")
            else { return }
            append(" ", attributes: base)
        }
        func converted(
            _ source: NSFont,
            trait: NSFontTraitMask
        ) -> NSFont {
            NSFontManager.shared.convert(source, toHaveTrait: trait)
        }
        func inlines(
            _ nodes: [MarkdownInlineNode],
            attributes: [NSAttributedString.Key: Any]
        ) {
            for node in nodes {
                switch node {
                case .text(let text), .html(let text), .math(let text, _):
                    append(text, attributes: attributes)
                case .code(let text):
                    var code = attributes
                    let size = (attributes[.font] as? NSFont)?.pointSize ?? font.pointSize
                    code[.font] = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                    append(text, attributes: code)
                case .softBreak, .lineBreak:
                    separator()
                case .emphasis(let children):
                    var emphasized = attributes
                    emphasized[.font] = converted(
                        attributes[.font] as? NSFont ?? font,
                        trait: .italicFontMask
                    )
                    inlines(children, attributes: emphasized)
                case .strong(let children):
                    var strong = attributes
                    strong[.font] = converted(
                        attributes[.font] as? NSFont ?? font,
                        trait: .boldFontMask
                    )
                    inlines(children, attributes: strong)
                case .strikethrough(let children):
                    var struck = attributes
                    struck[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    inlines(children, attributes: struck)
                case .link(let destination, let children):
                    var link = attributes
                    if let url = URL(string: destination) {
                        link[.link] = url
                        link[.foregroundColor] = NSColor.linkColor
                        link[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    inlines(children, attributes: link)
                case .image(_, let children):
                    inlines(children, attributes: attributes)
                }
            }
        }
        func blocks(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                separator()
                switch node {
                case .paragraph(let content), .heading(_, let content):
                    inlines(content, attributes: base)
                case .codeBlock(_, let content):
                    append(
                        content,
                        attributes: [
                            .font: NSFont.monospacedSystemFont(
                                ofSize: font.pointSize,
                                weight: .regular
                            ),
                            .foregroundColor: color,
                        ]
                    )
                case .blockquote(let children):
                    blocks(children)
                case .bulletedList(_, let items), .numberedList(_, _, let items):
                    for item in items { blocks(item.children) }
                case .taskList(_, let items):
                    for item in items { blocks(item.children) }
                case .table(_, let rows):
                    for row in rows {
                        for cell in row.cells {
                            inlines(cell.content, attributes: base)
                            separator()
                        }
                    }
                case .thematicBreak:
                    break
                }
            }
        }

        blocks(parse(source))
        let whitespace = try? NSRegularExpression(pattern: #"\s+"#)
        if let matches = whitespace?.matches(
            in: result.string,
            range: NSRange(location: 0, length: result.length)
        ) {
            for match in matches.reversed() {
                result.replaceCharacters(in: match.range, with: " ")
            }
        }
        while result.string.hasPrefix(" ") {
            result.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        while result.string.hasSuffix(" ") {
            result.deleteCharacters(
                in: NSRange(location: result.length - 1, length: 1)
            )
        }
        return result
    }

}

// MARK: - Rendered document

@MainActor
struct TermindMarkdownRenderedDocument {
    let content: MarkdownContent
    let theme: MarkdownTheme

    init(source: String, theme: TermindMarkdownTheme.Value) {
        content = MarkdownContent(markdown: source, theme: theme.theme)
        self.theme = theme.theme
    }
}

@MainActor
enum TermindMarkdownTheme {
    struct Value {
        let theme: MarkdownTheme
        let colorScheme: ColorScheme?
    }

    static func make(
        tone: TermindMarkdownTone,
        colorScheme: ColorScheme? = nil
    ) -> Value {
        var theme = MarkdownTheme()
        let bodySize = NSFont.systemFontSize
        let body = NSFont.systemFont(ofSize: bodySize)
        let codeSize = ceil(bodySize * MarkdownTheme.codeScale)

        theme.fonts.body = body
        theme.fonts.bold = NSFont.boldSystemFont(ofSize: bodySize)
        theme.fonts.italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        theme.fonts.codeInline = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        theme.fonts.code = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        theme.fonts.title = NSFont.boldSystemFont(ofSize: bodySize + 2)
        theme.fonts.largeTitle = NSFont.boldSystemFont(ofSize: bodySize + 5)

        let bodyColor = resolved(
            tone == .primary ? .labelColor : .secondaryLabelColor,
            colorScheme: colorScheme
        )
        theme.colors.body = bodyColor
        theme.colors.code = bodyColor
        theme.colors.highlight = resolved(.controlAccentColor, colorScheme: colorScheme)
        theme.colors.emphasis = resolved(.controlAccentColor, colorScheme: colorScheme)
        theme.colors.selectionBackground = resolved(
            .controlAccentColor, colorScheme: colorScheme
        ).withAlphaComponent(0.2)

        theme.spacings.paragraph = Metrics.Chat.blockSpacing
        theme.spacings.headingBefore = Metrics.Space.xs
        theme.spacings.list = Metrics.Space.xs
        return Value(theme: theme, colorScheme: colorScheme)
    }

    private static func resolved(_ color: NSColor, colorScheme: ColorScheme?) -> NSColor {
        guard let colorScheme,
            let appearance = NSAppearance(
                named: colorScheme == .dark ? .darkAqua : .aqua
            )
        else { return color }

        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }
}
