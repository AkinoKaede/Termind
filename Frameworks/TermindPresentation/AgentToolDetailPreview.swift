import AgentKit
import Foundation

/// A whole-card budget, not one budget per block. Full values remain untouched for expansion.
nonisolated public struct AgentToolDetailPreview: Equatable, Sendable {
    public static let characterLimit = 600
    public static let rowLimit = 5
    public let items: [AgentToolDetail.Item]
    public let fullItems: [AgentToolDetail.Item]
    public var isShortened: Bool { items != fullItems }

    public init(_ detail: AgentToolDetail) {
        fullItems = detail.items
        var budget = Budget()
        items = budget.project(detail.items)
    }

    public var fullText: String { Self.text(fullItems) }

    private static func text(_ items: [AgentToolDetail.Item]) -> String {
        items.map { item in
            switch item {
            case .field(let field): return field.label + ": " + field.value
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
        var characters = AgentToolDetailPreview.characterLimit
        var rows = AgentToolDetailPreview.rowLimit
        var hasRoom: Bool { characters > 0 && rows > 0 }

        mutating func take(_ value: String) -> String {
            guard characters > 0 else { return "" }
            let result = value.count > characters ? String(value.prefix(max(0, characters - 1))) + "…" : value
            characters -= result.count
            return result
        }

        mutating func optional(_ value: String?) -> String? {
            value.map { take($0) }
        }

        mutating func project(_ items: [AgentToolDetail.Item]) -> [AgentToolDetail.Item] {
            var result: [AgentToolDetail.Item] = []
            for item in items {
                guard hasRoom else { break }
                switch item {
                case .field(var field):
                    rows -= 1
                    field.label = take(field.label)
                    field.value = take(field.value)
                    result.append(.field(field))
                case .message(let value, let tint):
                    rows -= 1
                    result.append(.message(take(value), tint))
                case .text(var block):
                    rows -= 1
                    block.title = optional(block.title)
                    block.text = take(block.text)
                    result.append(.text(block))
                case .list(var list):
                    list.title = optional(list.title)
                    list.rows = projectRows(list.rows)
                    if list.rows.isEmpty {
                        rows -= 1
                        list.emptyMessage = optional(list.emptyMessage)
                    }
                    result.append(.list(list))
                case .groupedList(var list):
                    list.summary = take(list.summary)
                    var sections: [AgentToolDetail.ListSection] = []
                    for var section in list.sections {
                        guard hasRoom else { break }
                        section.title = take(section.title)
                        section.rows = projectRows(section.rows)
                        sections.append(section)
                    }
                    list.sections = sections
                    result.append(.groupedList(list))
                }
            }
            return result
        }

        mutating func projectRows(_ values: [AgentToolDetail.ListRow]) -> [AgentToolDetail.ListRow] {
            var result: [AgentToolDetail.ListRow] = []
            for var row in values {
                guard hasRoom else { break }
                rows -= 1
                row.title = take(row.title)
                row.subtitle = optional(row.subtitle)
                row.detail = optional(row.detail)
                row.badges = row.badges.compactMap { badge in
                    guard characters > 0 else { return nil }
                    return take(badge)
                }
                result.append(row)
            }
            return result
        }
    }
}
