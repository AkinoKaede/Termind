import Foundation
import MarkdownParser

nonisolated public enum TermindMarkdownParser {
    public static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]
    public static let shellLanguages: Set<String> = [
        "bash", "sh", "zsh", "shell", "console", "terminal",
    ]

    public static func parse(_ source: String) -> [MarkdownBlockNode] {
        let parsed = MarkdownParser().parse(MarkdownSoftBreaks.hardened(source))
        return sanitize(parsed.document)
    }

    public static func sanitize(_ blocks: [MarkdownBlockNode]) -> [MarkdownBlockNode] {
        blocks.rewrite { (inline: MarkdownInlineNode) -> [MarkdownInlineNode] in
            switch inline {
            case .link(let destination, let children):
                guard isAllowedLink(destination) else { return children }
                return [.link(destination: destination, children: children)]
            case .image(_, let children):
                // Never fetch a model-chosen URL while rendering a transcript.
                // The image's alt text remains readable ordinary prose.
                return children
            default:
                return [inline]
            }
        }
    }

    public static func isAllowedLink(_ destination: String) -> Bool {
        guard let scheme = URL(string: destination)?.scheme?.lowercased() else {
            return false
        }
        return allowedLinkSchemes.contains(scheme)
    }

    public static func isActionableShell(language: String?, code: String) -> Bool {
        guard let language else { return false }
        return shellLanguages.contains(language.lowercased())
            && !normalizedFenceCode(code).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func segments(
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
                case .codeBlock(let language, let code) = block,
                isActionableShell(language: language, code: code)
            {
                flushMarkdown()
                result.append(
                    .shell(
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

    public static func plainText(_ source: String) -> String {
        parse(source)
            .flatMap(plainText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// A portable single-line title that keeps inline emphasis and safe links.
    public static func inlineTitle(_ source: String) -> AttributedString {
        func inlines(_ nodes: [MarkdownInlineNode]) -> AttributedString {
            nodes.reduce(into: AttributedString()) { result, node in
                var value: AttributedString
                switch node {
                case .text(let text), .html(let text), .math(let text, _):
                    value = AttributedString(text)
                case .code(let text):
                    value = AttributedString(text)
                    value.inlinePresentationIntent = .code
                case .softBreak, .lineBreak:
                    value = AttributedString(" ")
                case .emphasis(let children):
                    value = inlines(children)
                    for run in value.runs {
                        value[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(
                            .emphasized)
                    }
                case .strong(let children):
                    value = inlines(children)
                    for run in value.runs {
                        value[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(
                            .stronglyEmphasized)
                    }
                case .strikethrough(let children):
                    value = inlines(children)
                    for run in value.runs {
                        value[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(
                            .strikethrough)
                    }
                case .link(let destination, let children):
                    value = inlines(children)
                    if isAllowedLink(destination) { value.link = URL(string: destination) }
                case .image(_, let children):
                    value = inlines(children)
                }
                result += value
            }
        }
        func blocks(_ nodes: [MarkdownBlockNode]) -> [AttributedString] {
            nodes.flatMap { node -> [AttributedString] in
                switch node {
                case .paragraph(let content), .heading(_, let content): [inlines(content)]
                case .codeBlock(_, let content):
                    [inlines([.code(content.trimmingCharacters(in: .whitespacesAndNewlines))])]
                case .blockquote(let children): blocks(children)
                case .bulletedList(_, let items), .numberedList(_, _, let items): items.flatMap { blocks($0.children) }
                case .taskList(_, let items): items.flatMap { blocks($0.children) }
                case .table(_, let rows): rows.flatMap { $0.cells.map { inlines($0.content) } }
                case .thematicBreak: []
                }
            }
        }
        return blocks(parse(source)).enumerated().reduce(into: AttributedString()) { result, item in
            if item.offset > 0 { result += AttributedString(" ") }
            result += item.element
        }
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

nonisolated public enum TermindMarkdownBlockSegment: Equatable, Sendable {
    case markdown([MarkdownBlockNode])
    case shell(language: String, command: String)
}
