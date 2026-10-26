// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import SwiftUI

/// Resource-specific content within the existing transcript chrome, not another nested card.
public struct ResourceToolCardView: View {
    private let content: ResourceToolCardContent
    @Binding private var expanded: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 46.0

    public init(content: ResourceToolCardContent, expanded: Binding<Bool>) {
        self.content = content
        _expanded = expanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !content.title.isEmpty {
                Text(content.title).font(.callout.weight(.medium)).lineLimit(expanded ? nil : 2)
            }
            AssistantToolDetails(items: content.notices)
            ForEach(content.fields.indices, id: \.self) { field(content.fields[$0]) }
            if !content.route.isEmpty { adaptiveColumns(content.route, route: true) }
            if !content.measurements.isEmpty { adaptiveColumns(content.measurements, route: false) }
            if content.isList {
                let rows = content.visibleRows(expanded: expanded)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rows.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rows[index].title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(rows[index].subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(height: min(expanded ? 320 : 240, Double(rows.count) * rowHeight))
            }
            if expanded {
                ForEach(content.details.indices, id: \.self) { field(content.details[$0]) }
            }
            ForEach(content.blocks.indices, id: \.self) { index in
                let block = content.blocks[index]
                if expanded || !block.expandedOnly { textBlock(block) }
            }
            if content.canExpand {
                Button(expanded ? AppStrings.Assistant.showLess.swiftUIKey : AppStrings.Assistant.showMore.swiftUIKey) {
                    expanded.toggle()
                }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityIdentifier("AssistantTool.More")
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("AssistantTool.ResourceCard")
    }

    @ViewBuilder private func field(_ field: AgentToolDetail.Field) -> some View {
        if dynamicTypeSize.isAccessibilitySize || field.value.count > 48 || field.value.contains("\n") {
            verticalField(field)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(field.label).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 8)
                    Text(field.value).fixedSize()
                }
                verticalField(field)
            }
            .font(.caption)
        }
    }

    private func verticalField(_ field: AgentToolDetail.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(field.value).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func adaptiveColumns(_ fields: [AgentToolDetail.Field], route: Bool) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            columns(fields, horizontal: false, route: route)
        } else {
            ViewThatFits(in: .horizontal) {
                columns(fields, horizontal: true, route: route).fixedSize(horizontal: true, vertical: false)
                columns(fields, horizontal: false, route: route)
            }
        }
    }

    private func columns(_ fields: [AgentToolDetail.Field], horizontal: Bool, route: Bool) -> some View {
        let layout =
            horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            ForEach(fields.indices, id: \.self) { index in
                if route && index > 0 {
                    Image(systemName: horizontal ? "arrow.right" : "arrow.down")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(fields[index].label).font(.caption).foregroundStyle(.secondary)
                    Text(fields[index].value)
                        .font(route ? .caption.monospaced() : .title3.monospacedDigit())
                }
            }
        }
    }

    private func textBlock(_ block: ResourceToolCardContent.Block) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(block.text)
                        .font(block.monospaced ? .caption.monospaced() : .caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(
                    height: min(200, max(64, Double(block.text.components(separatedBy: "\n").count) * rowHeight / 2)))
            } else {
                Text(block.text).font(block.monospaced ? .caption.monospaced() : .caption)
                    .lineLimit(block.previewLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
