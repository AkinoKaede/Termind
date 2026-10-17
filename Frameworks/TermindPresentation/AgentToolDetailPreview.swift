import AgentKit
import Foundation

/// A whole-card budget, not one budget per block. Full values remain untouched for expansion.
nonisolated public struct AgentToolDetailPreview: Equatable, Sendable {
    public static let byteLimit = AgentTruncateLimits.maximumBytes
    public static let rowLimit = 5
    public let items: [AgentToolDetail.Item]
    public let fullItems: [AgentToolDetail.Item]
    public var isShortened: Bool { items != fullItems }

    public init(
        _ detail: AgentToolDetail, strategy: AgentTruncateStrategy = .head, preservesFirstText: Bool = false
    ) {
        fullItems = detail.items
        var budget = Budget(strategy: strategy, preservesFirstText: preservesFirstText)
        items = budget.project(detail.items)
    }

    public var fullText: String { Self.text(fullItems) }

    private static func text(_ items: [AgentToolDetail.Item]) -> String {
        items.map { item in
            switch item {
            case .field(let field): return field.value.isEmpty ? field.label : field.label + ": " + field.value
            case .message(let value, _): return value
            case .text(let block): return [block.title, block.text].compactMap { $0 }.joined(separator: "\n")
            case .list(let list):
                return
                    ([list.title].compactMap { $0 } + list.rows.map(rowText)
                    + (list.rows.isEmpty ? [list.emptyMessage].compactMap { $0 } : [])).joined(separator: "\n")
            case .groupedList(let list):
                return
                    ([list.summary]
                    + list.sections.map {
                        ([$0.title] + $0.rows.map(rowText)).joined(separator: "\n")
                    }).joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    private static func rowText(_ row: AgentToolDetail.ListRow) -> String {
        ([row.title, row.subtitle, row.detail].compactMap { $0 } + row.badges).joined(separator: "\n")
    }

    private struct Budget {
        var rows = AgentToolDetailPreview.rowLimit
        var bytes = AgentToolDetailPreview.byteLimit
        var strategy: AgentTruncateStrategy
        var preservesFirstText: Bool

        mutating func project(_ items: [AgentToolDetail.Item]) -> [AgentToolDetail.Item] {
            var result: [AgentToolDetail.Item] = []
            for item in items {
                switch item {
                case .field, .message:
                    // Command metadata and notices are never part of the body budget.
                    result.append(item)
                case .text(var block):
                    if preservesFirstText {
                        preservesFirstText = false
                        result.append(item)
                        continue
                    }
                    let selected = AgentTruncateResult.apply(
                        block.text, strategy: strategy,
                        limits: .init(bytes: bytes, lines: max(0, rows)))
                    rows -= selected.returnedLines
                    bytes -= selected.content.utf8.count
                    block.text = selected.content
                    if !block.text.isEmpty { result.append(.text(block)) }
                case .list(var list):
                    list.rows = projectRows(list.rows)
                    result.append(.list(list))
                case .groupedList(var list):
                    list.sections = list.sections.compactMap { section in
                        guard rows > 0 else { return nil }
                        var section = section
                        section.rows = projectRows(section.rows)
                        return section
                    }
                    result.append(.groupedList(list))
                }
            }
            return result
        }

        mutating func projectRows(_ values: [AgentToolDetail.ListRow]) -> [AgentToolDetail.ListRow] {
            var result: [AgentToolDetail.ListRow] = []
            for value in values.prefix(max(0, rows)) {
                let size = AgentToolDetailPreview.rowText(value).utf8.count
                guard size <= bytes else { break }
                result.append(value)
                bytes -= size
            }
            rows -= result.count
            return result
        }
    }
}
