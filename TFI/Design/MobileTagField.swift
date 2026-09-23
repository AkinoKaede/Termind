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
                TagFlowLayout(spacing: 6, widthSizing: .intrinsic) {
                    ForEach(tags, id: \.self) { tag in
                        MobileRemovableTagChip(tag: tag) {
                            tags = TagFieldPolicy.removing(tag, from: tags)
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField(
                        text: $query.singleLineText, prompt: Text(AppStrings.Vault.addATagProgress), axis: .horizontal
                    ) {
                        EmptyView()
                    }
                    .singleLinePaste()
                    .lineLimit(1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit(commitQuery)
                    .accessibilityLabel(Text(AppStrings.Vault.addATagProgress))
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

    private var rows: [TagFieldPolicy.Row] {
        TagFieldPolicy.rows(tags: tags, suggestions: suggestions, query: query)
    }

    private func commitQuery() {
        guard let tag = TagFieldPolicy.submission(query: query, suggestions: suggestions) else {
            isFocused = false
            return
        }
        add(tag)
    }

    private func commit(_ row: TagFieldPolicy.Row) {
        switch row {
        case .existing(let tag), .create(let tag):
            add(tag)
        }
    }

    private func add(_ tag: String) {
        tags = TagFieldPolicy.adding(tag, to: tags)
        query = ""
        isFocused = true
    }
}

private struct MobileTagSuggestionRow: View {
    let row: TagFieldPolicy.Row

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
                Text(AppStrings.Vault.createNamed(tag))
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
            .accessibilityLabel(Text(AppStrings.Vault.removeTag(tag)))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}
