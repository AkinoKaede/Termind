// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// A UI-only allowlist. Protocol payloads and their persisted representation stay unchanged.
nonisolated public struct ResourceToolCardContent: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var title: String
        public var subtitle: String
    }

    public struct Block: Equatable, Sendable {
        public var title: String
        public var text: String
        public var monospaced: Bool
        public var previewLines: Int
        public var expandedOnly: Bool
    }

    public var title = ""
    public var fields: [AgentToolDetail.Field] = []
    public var details: [AgentToolDetail.Field] = []
    public var blocks: [Block] = []
    public var rows: [Row] = []
    public var isList = false
    public var route: [AgentToolDetail.Field] = []
    public var measurements: [AgentToolDetail.Field] = []
    public var notices: [AgentToolDetail.Item] = []

    public var canExpand: Bool {
        !details.isEmpty || rows.count > 5 || !blocks.isEmpty
    }

    public func visibleRows(expanded: Bool) -> [Row] {
        expanded ? rows : Array(rows.prefix(5))
    }

    /// Safe fallback for non-card surfaces, including history replay without a registered presenter.
    public var detail: AgentToolDetail {
        var items = notices
        if !title.isEmpty { items.append(.field(.init(label: "", value: title))) }
        items += (fields + route + measurements).map { .field($0) }
        if isList {
            items.append(.list(.init(rows: rows.map { .init(title: $0.title, subtitle: $0.subtitle) })))
        }
        items += details.map { .field($0) }
        items += blocks.map {
            .text(.init(title: $0.title, text: $0.text, style: $0.monospaced ? .monospaced : .plain))
        }
        return .init(items: items)
    }
}
