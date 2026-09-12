import AppKit
import Combine
import MarkdownParser
import MarkdownView
import SwiftUI
import TermindApplication
import TermindPresentation

/// The Markdown entry point used by the transcript.
///
/// MarkdownView owns parsing, block layout, tables, syntax highlighting and
/// text selection. Termind keeps a thin policy layer around it for the two
/// things a general renderer must not decide for this app: which links are safe
/// to open and which assistant-authored shell fences may reach a terminal.
struct TermindMarkdownView: View {
    enum Tone: Hashable {
        case primary
        case secondary
    }

    let text: String
    var isStreaming = false
    var isAssistant = true
    var tone: Tone = .primary

    @Environment(\.markdownFillsWidth) private var fillsWidth
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: RenderingModel

    init(
        text: String,
        isStreaming: Bool = false,
        isAssistant: Bool = true,
        isCompact _: Bool = false,
        tone: Tone = .primary
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.isAssistant = isAssistant
        self.tone = tone

        let theme = TermindMarkdownTheme.make(tone: tone)
        _model = StateObject(
            wrappedValue: RenderingModel(
                source: text,
                allowsShellActions: isAssistant,
                theme: theme
            ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Chat.blockSpacing) {
            ForEach(model.rendered.segments) { segment in
                switch segment.content {
                case .markdown(let content):
                    TermindMarkdownNativeView(
                        content: content,
                        theme: model.rendered.theme,
                        fillsWidth: fillsWidth
                    )
                case .shell(let language, let command):
                    AssistantShellCodeBlockView(
                        language: language,
                        command: command
                    )
                }
            }
        }
        .markdownWidth(fills: fillsWidth)
        .onChange(
            of: UpdateID(
                text: text,
                isStreaming: isStreaming,
                isAssistant: isAssistant,
                tone: tone,
                colorScheme: colorScheme
            ),
            initial: true
        ) { _, _ in
            refreshIfNeeded()
        }
    }

    /// MarkdownView is designed for streaming, but splitting actionable shell
    /// blocks still requires a root parse. Upstream's balanced emitter already
    /// controls the presentation cadence, so every emitted delta is rendered
    /// immediately instead of being throttled again at the view layer.
    private func refreshIfNeeded() {
        guard
            model.source != text
                || model.rendered.allowsShellActions != isAssistant
                || model.rendered.themeTone != tone
                || model.rendered.themeColorScheme != colorScheme
        else { return }
        refresh()
    }

    private func refresh() {
        model.refresh(
            source: text,
            allowsShellActions: isAssistant,
            theme: TermindMarkdownTheme.make(tone: tone, colorScheme: colorScheme)
        )
    }

    private struct UpdateID: Hashable {
        let text: String
        let isStreaming: Bool
        let isAssistant: Bool
        let tone: Tone
        let colorScheme: ColorScheme
    }

    @MainActor
    private final class RenderingModel: ObservableObject {
        @Published private(set) var rendered: TermindMarkdownRenderedDocument
        private(set) var source: String

        init(
            source: String,
            allowsShellActions: Bool,
            theme: TermindMarkdownTheme.Value
        ) {
            self.source = source
            rendered = TermindMarkdownRenderedDocument(
                source: source,
                allowsShellActions: allowsShellActions,
                theme: theme
            )
        }

        func refresh(
            source: String,
            allowsShellActions: Bool,
            theme: TermindMarkdownTheme.Value
        ) {
            rendered = TermindMarkdownRenderedDocument(
                source: source,
                allowsShellActions: allowsShellActions,
                theme: theme
            )
            self.source = source
        }
    }
}

private struct MarkdownFillsWidthKey: EnvironmentKey {
    nonisolated static let defaultValue = true
}

extension EnvironmentValues {
    /// Assistant prose and plans fill their reading column. User messages opt
    /// out so a short question keeps a short bubble.
    var markdownFillsWidth: Bool {
        get { self[MarkdownFillsWidthKey.self] }
        set { self[MarkdownFillsWidthKey.self] = newValue }
    }
}

extension View {
    func markdownWidth(fills: Bool, alignment: Alignment = .leading) -> some View {
        frame(maxWidth: fills ? .infinity : nil, alignment: alignment)
    }
}

/// Kept as the transcript-wide type scale for non-Markdown labels and the
/// Termind-owned shell card. MarkdownView receives matching AppKit fonts below.
enum MarkdownTypography {
    static let body = Font.body
    static let monospaced = Font.system(.body, design: .monospaced)
}

// MARK: - Parsing policy

extension TermindMarkdownParser {
    /// A one-line AppKit projection for transient tool titles. It applies the
    /// same sanitization as the full transcript renderer, preserves inline
    /// emphasis/code/strikethrough/safe links, and flattens block structure
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
                    if let url = URL(string: destination), isAllowedLink(destination) {
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
    struct Segment: Identifiable {
        enum Content {
            case markdown(MarkdownContent)
            case shell(language: String, command: String)
        }

        let id: Int
        let content: Content
    }

    let segments: [Segment]
    let theme: MarkdownTheme
    let allowsShellActions: Bool
    let themeTone: TermindMarkdownView.Tone
    let themeColorScheme: ColorScheme?

    init(source: String, allowsShellActions: Bool, theme: TermindMarkdownTheme.Value) {
        let parserResult = MarkdownParser().parse(MarkdownSoftBreaks.hardened(source))
        let blocks = TermindMarkdownParser.sanitize(parserResult.document)
        let rendered = parserResult.renderedContent(theme: theme.theme)
        let highlights = parserResult.highlightMaps(theme: theme.theme)

        segments = TermindMarkdownParser.segments(
            from: blocks,
            allowsShellActions: allowsShellActions
        ).enumerated().map { index, segment in
            switch segment {
            case .markdown(let segmentBlocks):
                let content = MarkdownContent(
                    blocks: segmentBlocks,
                    rendered: rendered,
                    highlightMaps: highlights,
                    locale: .autoupdatingCurrent
                )
                return Segment(id: index, content: .markdown(content))
            case .shell(let language, let command):
                return Segment(
                    id: index,
                    content: .shell(language: language, command: command)
                )
            }
        }
        self.theme = theme.theme
        self.allowsShellActions = allowsShellActions
        themeTone = theme.tone
        themeColorScheme = theme.colorScheme
    }
}

@MainActor
enum TermindMarkdownTheme {
    struct Value {
        let theme: MarkdownTheme
        let tone: TermindMarkdownView.Tone
        let colorScheme: ColorScheme?
    }

    static func make(
        tone: TermindMarkdownView.Tone,
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
        theme.colors.codeBackground = resolved(
            .secondaryLabelColor, colorScheme: colorScheme
        ).withAlphaComponent(0.15)
        theme.colors.selectionBackground = resolved(
            .controlAccentColor, colorScheme: colorScheme
        ).withAlphaComponent(0.2)

        theme.spacings.paragraph = Metrics.Chat.blockSpacing
        theme.spacings.headingBefore = Metrics.Space.xs
        theme.spacings.list = Metrics.Space.xs
        theme.table.cornerRadius = Metrics.Radius.small
        theme.table.borderColor = resolved(.separatorColor, colorScheme: colorScheme)
        theme.table.headerBackgroundColor = resolved(
            .quaternaryLabelColor, colorScheme: colorScheme
        ).withAlphaComponent(0.12)
        theme.table.stripeCellBackgroundColor = resolved(
            .quaternaryLabelColor, colorScheme: colorScheme
        ).withAlphaComponent(0.06)
        return Value(theme: theme, tone: tone, colorScheme: colorScheme)
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

// MARK: - AppKit bridge

private struct TermindMarkdownNativeView: NSViewRepresentable {
    let content: MarkdownContent
    let theme: MarkdownTheme
    let fillsWidth: Bool

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(fillsWidth ? .defaultLow : .required, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.linkHandler = { payload, _, _ in
            TermindMarkdownLinkOpener.open(payload)
        }
        context.coordinator.apply(content: content, theme: theme, to: view)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        view.setContentHuggingPriority(fillsWidth ? .defaultLow : .required, for: .horizontal)
        context.coordinator.apply(content: content, theme: theme, to: view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: MarkdownTextView,
        context: Context
    ) -> CGSize? {
        context.coordinator.sizeThatFits(
            proposal,
            view: view,
            fillsWidth: fillsWidth
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private var lastContent: MarkdownContent?
        private var lastTheme: MarkdownTheme?
        private var concreteWidth: CGFloat = 0

        func apply(content: MarkdownContent, theme: MarkdownTheme, to view: MarkdownTextView) {
            guard lastContent !== content || lastTheme != theme else { return }
            view.setContentImmediately(content, theme: theme)
            view.invalidateIntrinsicContentSize()
            lastContent = content
            lastTheme = theme
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            view: MarkdownTextView,
            fillsWidth: Bool
        ) -> CGSize? {
            if proposal.width == 0 { return .zero }

            let availableWidth: CGFloat
            if let width = proposal.width, width.isFinite, width > 0 {
                availableWidth = width
                concreteWidth = width
            } else if concreteWidth > 0 {
                availableWidth = concreteWidth
            } else if view.bounds.width > 0 {
                availableWidth = view.bounds.width
            } else {
                return nil
            }

            let bounded = view.boundingSize(for: availableWidth)
            let width =
                fillsWidth
                ? availableWidth
                : min(availableWidth, max(1, ceil(bounded.width)))
            let height = ceil(view.boundingSize(for: width).height)
            return CGSize(width: width, height: height)
        }
    }
}

@MainActor
private enum TermindMarkdownLinkOpener {
    static func open(_ payload: LinkPayload) {
        let url: URL?
        switch payload {
        case .url(let value):
            url = value
        case .string(let value):
            url = URL(string: value)
        }
        guard let url,
            TermindMarkdownParser.allowedLinkSchemes.contains(
                url.scheme?.lowercased() ?? ""
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}
