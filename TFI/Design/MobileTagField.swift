import SwiftUI
import TermindPresentation

struct MobileTagField: View {
    @Binding var tags: [String]
    let suggestions: [String]

    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                MobileTagFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        MobileRemovableTagChip(tag: tag) {
                            tags = MobileTagFieldPolicy.removing(tag, from: tags)
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField(text: $query.singleLineText, prompt: Text("Add a tag…"), axis: .horizontal) {
                        EmptyView()
                    }
                    .singleLinePaste()
                    .lineLimit(1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit(commitQuery)
                    .accessibilityLabel(Text("Add a tag…"))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)

                if isFocused && !rows.isEmpty {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.self) { row in
                                Button {
                                    commit(row)
                                } label: {
                                    MobileTagSuggestionRow(row: row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(rows.count), 4) * 44)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
    }

    private var rows: [MobileTagFieldPolicy.Row] {
        MobileTagFieldPolicy.rows(tags: tags, suggestions: suggestions, query: query)
    }

    private func commitQuery() {
        guard let tag = MobileTagFieldPolicy.submission(query: query, suggestions: suggestions) else {
            isFocused = false
            return
        }
        add(tag)
    }

    private func commit(_ row: MobileTagFieldPolicy.Row) {
        switch row {
        case .existing(let tag), .create(let tag):
            add(tag)
        }
    }

    private func add(_ tag: String) {
        tags = MobileTagFieldPolicy.adding(tag, to: tags)
        query = ""
        isFocused = true
    }
}

nonisolated enum MobileTagFieldPolicy {
    enum Row: Hashable, Sendable {
        case existing(String)
        case create(String)
    }

    static func rows(tags: [String], suggestions: [String], query: String) -> [Row] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        let taken = Set(tags.map { $0.lowercased() })
        let matches =
            suggestions
            .filter { !taken.contains($0.lowercased()) }
            .filter { trimmedQuery.isEmpty || $0.localizedCaseInsensitiveContains(trimmedQuery) }

        guard !trimmedQuery.isEmpty else { return matches.map(Row.existing) }
        let spokenFor = taken.union(suggestions.map { $0.lowercased() })
        guard !spokenFor.contains(trimmedQuery.lowercased()) else { return matches.map(Row.existing) }
        return matches.map(Row.existing) + [.create(trimmedQuery)]
    }

    static func submission(query: String, suggestions: [String]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return suggestions.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    static func adding(_ tag: String, to tags: [String]) -> [String] {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return tags }
        return tags + [trimmed]
    }

    static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0 != tag }
    }
}

private struct MobileTagSuggestionRow: View {
    let row: MobileTagFieldPolicy.Row

    var body: some View {
        HStack(spacing: 8) {
            switch row {
            case .existing(let tag):
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                Text(tag)
            case .create(let tag):
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                Text("Create “\(tag)”")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct MobileRemovableTagChip: View {
    let tag: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove tag \(tag)"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

private struct MobileTagFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(CGFloat.zero) { width, subview in
            width + subview.sizeThatFits(.unspecified).width + (width == 0 ? 0 : spacing)
        }
        let proposedWidth = proposal.width ?? naturalWidth
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : naturalWidth
        let rows = arrange(subviews: subviews, in: width)
        let height =
            rows.reduce(CGFloat.zero) { $0 + $1.height }
            + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct RowRun {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [RowRun] {
        var rows: [RowRun] = []
        var current = RowRun()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty && x + size.width > width {
                rows.append(current)
                current = RowRun()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
