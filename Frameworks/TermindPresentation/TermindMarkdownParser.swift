// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MarkdownParser

nonisolated public enum TermindMarkdownParser {
    public static func parse(_ source: String) -> [MarkdownBlockNode] {
        MarkdownParser().parse(source).document
    }

    public static func plainText(_ source: String) -> String {
        parse(source)
            .flatMap(plainText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// A portable single-line title that keeps inline emphasis and links.
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
                    value.link = URL(string: destination)
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
