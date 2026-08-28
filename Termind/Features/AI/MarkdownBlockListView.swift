import AppKit
import Combine
import MarkdownParser
import MarkdownView
import SwiftUI

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
        _model = StateObject(wrappedValue: RenderingModel(
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
        .task(id: UpdateID(
            text: text,
            isStreaming: isStreaming,
            isAssistant: isAssistant,
            tone: tone
        )) {
            await refreshIfNeeded()
        }
    }

    /// MarkdownView is designed for streaming, but splitting actionable shell
    /// blocks still requires a root parse. Apply the first delta immediately,
    /// coalesce ordinary deltas to 20 fps, and force a refresh once a line of
    /// unseen text accumulates so an uninterrupted stream can never stay stale.
    private func refreshIfNeeded() async {
        guard model.source != text
            || model.rendered.allowsShellActions != isAssistant
            || model.rendered.themeTone != tone
        else { return }

        if !isStreaming
            || !text.hasPrefix(model.source)
            || text.utf8.count - model.source.utf8.count >= 64
        {
            refresh()
            return
        }

        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        refresh()
    }

    private func refresh() {
        model.refresh(
            source: text,
            allowsShellActions: isAssistant,
            theme: TermindMarkdownTheme.make(tone: tone)
        )
    }

    private struct UpdateID: Hashable {
        let text: String
        let isStreaming: Bool
        let isAssistant: Bool
        let tone: Tone
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

nonisolated enum TermindMarkdownParser {
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]
    static let shellLanguages: Set<String> = [
        "bash", "sh", "zsh", "shell", "console", "terminal",
    ]

    static func parse(_ source: String) -> [MarkdownBlockNode] {
        let parsed = MarkdownParser().parse(MarkdownSoftBreaks.hardened(source))
        return sanitize(parsed.document)
    }

    static func sanitize(_ blocks: [MarkdownBlockNode]) -> [MarkdownBlockNode] {
        blocks.rewrite { (inline: MarkdownInlineNode) -> [MarkdownInlineNode] in
            switch inline {
            case let .link(destination, children):
                guard isAllowedLink(destination) else { return children }
                return [.link(destination: destination, children: children)]
            case let .image(_, children):
                // Never fetch a model-chosen URL while rendering a transcript.
                // The image's alt text remains readable ordinary prose.
                return children
            default:
                return [inline]
            }
        }
    }

    static func isAllowedLink(_ destination: String) -> Bool {
        guard let scheme = URL(string: destination)?.scheme?.lowercased() else {
            return false
        }
        return allowedLinkSchemes.contains(scheme)
    }

    static func isActionableShell(language: String?, code: String) -> Bool {
        guard let language else { return false }
        return shellLanguages.contains(language.lowercased())
            && !normalizedFenceCode(code).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func segments(
        from blocks: [MarkdownBlockNode],
        allowsShellActions: Bool
    ) -> [TermindMarkdownBlockSegment] {
        var result: [TermindMarkdownBlockSegment] = []
        var markdown: [MarkdownBlockNode] = []

        func flushMarkdown() {
            guard !markdown.isEmpty else { return }
            result.append(.markdown(markdown))
            markdown.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if allowsShellActions,
               case let .codeBlock(language, code) = block,
               isActionableShell(language: language, code: code)
            {
                flushMarkdown()
                result.append(.shell(
                    language: language ?? "",
                    command: normalizedFenceCode(code)
                ))
            } else {
                markdown.append(block)
            }
        }
        flushMarkdown()
        return result
    }

    /// cmark includes the structural newline immediately before a closing
    /// fence. It is not part of the command and must not make a one-line shell
    /// suggestion look like a multi-line script to the execution guard.
    private static func normalizedFenceCode(_ code: String) -> String {
        code.hasSuffix("\n") ? String(code.dropLast()) : code
    }

    static func plainText(_ source: String) -> String {
        parse(source)
            .flatMap(plainText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func plainText(_ block: MarkdownBlockNode) -> [String] {
        switch block {
        case .paragraph(let content), .heading(_, let content):
            [plainText(content)]
        case .codeBlock(_, let content):
            [content]
        case .blockquote(let children):
            children.flatMap(plainText)
        case .bulletedList(_, let items), .numberedList(_, _, let items):
            items.flatMap { $0.children.flatMap(plainText) }
        case .taskList(_, let items):
            items.flatMap { $0.children.flatMap(plainText) }
        case .table(_, let rows):
            rows.flatMap { row in row.cells.map { plainText($0.content) } }
        case .thematicBreak:
            []
        }
    }

    private static func plainText(_ inlines: [MarkdownInlineNode]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .code(let text), .html(let text), .math(let text, _):
                text
            case .softBreak, .lineBreak:
                " "
            case .emphasis(let children), .strong(let children),
                 .strikethrough(let children), .link(_, let children),
                 .image(_, let children):
                plainText(children)
            }
        }.joined()
    }
}

nonisolated enum TermindMarkdownBlockSegment: Equatable, Sendable {
    case markdown([MarkdownBlockNode])
    case shell(language: String, command: String)
}

// MARK: - Rendered document

@MainActor
private struct TermindMarkdownRenderedDocument {
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
    }
}

@MainActor
private enum TermindMarkdownTheme {
    struct Value {
        let theme: MarkdownTheme
        let tone: TermindMarkdownView.Tone
    }

    static func make(tone: TermindMarkdownView.Tone) -> Value {
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

        let bodyColor: NSColor = tone == .primary ? .labelColor : .secondaryLabelColor
        theme.colors.body = bodyColor
        theme.colors.code = bodyColor
        theme.colors.highlight = .controlAccentColor
        theme.colors.emphasis = .controlAccentColor
        theme.colors.codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.15)
        theme.colors.selectionBackground = NSColor.controlAccentColor.withAlphaComponent(0.2)

        theme.spacings.paragraph = Metrics.Chat.blockSpacing
        theme.spacings.headingBefore = Metrics.Space.xs
        theme.spacings.list = Metrics.Space.xs
        theme.table.cornerRadius = Metrics.Radius.small
        theme.table.borderColor = .separatorColor
        theme.table.headerBackgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        theme.table.stripeCellBackgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        return Value(theme: theme, tone: tone)
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
            let width = fillsWidth
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
