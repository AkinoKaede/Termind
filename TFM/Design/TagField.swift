import SwiftUI
import TermindApplication
import TermindPresentation

/// A token field: the tags already chosen, shown as removable chips, over a
/// search field that narrows the tags in use elsewhere and offers to create the
/// typed one.
///
/// It replaces a comma-separated `TextField`, which asked the user to remember
/// how a tag was spelled the last time. A typo there is silent and permanent —
/// `postgres` and `Postgres` are two tags forever, and neither finds the other
/// in search. Offering what exists is the fix; `Create "…"` stays as an explicit
/// row rather than a side effect of pressing Return on something unrecognised,
/// so making a new tag is always a thing the user chose to do.
///
/// Lives in `Design/` because snippets carry tags too, and their editor
/// reuses this desktop token field unchanged.
struct TagField: View {
    @Binding var tags: [String]
    /// Every tag worth offering — `HostLibraryModel.allTags` at every call site so far.
    /// Passed in rather than read from the environment so the control stays a
    /// plain value: the snippet editor will hand it the same list.
    let suggestions: [String]

    @State private var query = ""
    @State private var highlighted: Int?
    /// Whether the dropdown is open, tracked separately from focus.
    ///
    /// Focus alone is not enough to gate it: the field keeps focus after a tag
    /// is committed, so a list gated on focus is a list with no way to put it
    /// away. This is what Escape and the chevron write to.
    @State private var showsList = false
    @FocusState private var isFocused: Bool

    /// The dropdown's ceiling. Six rows and a bit, so a long list reads as
    /// scrollable rather than running the form row off the window.
    private let listMaxHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !tags.isEmpty {
                chips
            }

            VStack(alignment: .leading, spacing: 0) {
                field

                if isListOpen {
                    Divider()
                    list
                }
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Metrics.Radius.medium))
        }
        .animation(Motion.panel, value: rows)
        .animation(Motion.panel, value: isListOpen)
        .animation(Motion.panel, value: tags)
        // Moving to another field puts the list away, so it never hangs over a
        // form the user has moved on from.
        .onChange(of: isFocused) { _, focused in
            if focused { showsList = true } else { showsList = false }
        }
    }

    private var isListOpen: Bool { showsList && !rows.isEmpty }

    // MARK: - Pieces

    private var chips: some View {
        TagFlowLayout(spacing: Metrics.Space.xs, widthSizing: .proposed) {
            ForEach(tags, id: \.self) { tag in
                RemovableTagChip(tag: tag) { remove(tag) }
            }
        }
    }

    private var field: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)

            TextField(text: $query.singleLineText, prompt: Text(TermindCopy.Vault.addATagProgress), axis: .horizontal) {
                EmptyView()
            }
            .singleLinePaste()
            .lineLimit(1)
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .accessibilityLabel(Text(TermindCopy.Vault.addATagProgress))
            .focused($isFocused)
            // Return takes the highlighted row, so the whole interaction is
            // type-then-Return without reaching for the arrow keys. A
            // focused field's submit is handled before the Save button's
            // `.defaultAction`, so this does not save the host by accident.
            .onSubmit(commitHighlighted)
            // And when the arrows are reached for, they move the highlight
            // without the field giving up focus — correcting the query is
            // always one keystroke away.
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            // A comma commits, because that is what the field this replaces
            // was made of and the habit outlives the control.
            .onKeyPress(",") {
                commitHighlighted()
                return .handled
            }
            // Backspace on an empty query eats the last chip — the token
            // field contract everywhere else on the platform.
            .onKeyPress(.delete) {
                guard query.isEmpty, let last = tags.last else { return .ignored }
                remove(last)
                return .handled
            }
            // Escape puts the list away and drops what was typed. Handing
            // the key back when there is nothing left to dismiss is what
            // leaves the editor's Cancel button its `.cancelAction`, so a
            // second Escape still closes the form.
            .onKeyPress(.escape) {
                guard showsList || !query.isEmpty else { return .ignored }
                query = ""
                showsList = false
                return .handled
            }

            // The same dismissal for a hand on the mouse. Also the way back in
            // once the list has been closed without moving focus.
            Button {
                showsList.toggle()
                isFocused = true
            } label: {
                Image(systemName: isListOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(isListOpen ? TermindCopy.Vault.hideTagSuggestions : TermindCopy.Vault.showTagSuggestions))
        }
        .padding(Metrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A row can leave the visible window as the query narrows the list, and
        // a highlight nobody can see is the same as no highlight.
        .onChange(of: query) { _, _ in
            highlighted = rows.isEmpty ? nil : 0
            // Typing always means "show me what matches", including after the
            // list was dismissed with Escape.
            showsList = true
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                        TagRowView(row: row, isHighlighted: highlighted == index)
                            .id(row)
                            // Single click commits: this is a picker, not a list of objects
                            // to select and then act on.
                            .onTapGesture {
                                commit(row)
                            }
                    }
                }
                .padding(.vertical, Metrics.Space.xxs)
            }
            .onAppear { scrollHighlightIntoView(using: proxy) }
            .onChange(of: highlighted) { _, _ in scrollHighlightIntoView(using: proxy) }
            .onChange(of: rows) { _, _ in scrollHighlightIntoView(using: proxy) }
        }
        .frame(maxHeight: listMaxHeight)
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func scrollHighlightIntoView(using proxy: ScrollViewProxy) {
        guard let highlighted, rows.indices.contains(highlighted) else { return }
        proxy.scrollTo(rows[highlighted])
    }

    // MARK: - Rows

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var rows: [TagFieldPolicy.Row] {
        TagFieldPolicy.rows(tags: tags, suggestions: suggestions, query: query)
    }

    // MARK: - Editing

    /// Moves the highlight by `delta`, clamped rather than wrapped: running off
    /// the end of a list and reappearing at the other is how the wrong row gets
    /// picked.
    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        // An arrow after Escape means "show me that list again" — the key is
        // asking to move within something, so it has to be on screen.
        showsList = true
        guard let current = highlighted else {
            highlighted = delta > 0 ? 0 : rows.count - 1
            return .handled
        }
        highlighted = min(max(current + delta, 0), rows.count - 1)
        return .handled
    }

    /// Return with nothing highlighted still commits what was typed, so a tag
    /// can be added without ever looking at the list. A closed list has no
    /// highlight to honour either, however stale the index — Return there means
    /// the text, not the row that happened to be under it before Escape.
    private func commitHighlighted() {
        if isListOpen, let highlighted, rows.indices.contains(highlighted) {
            commit(rows[highlighted])
        } else if !trimmedQuery.isEmpty {
            add(trimmedQuery)
        }
    }

    private func commit(_ row: TagFieldPolicy.Row) {
        switch row {
        case .existing(let tag), .create(let tag): add(tag)
        }
    }

    /// Appends rather than sorts: the order tags were chosen in is the order the
    /// host lists them, and a chip that jumps elsewhere the moment it is added
    /// is a chip nobody can find again to remove.
    private func add(_ tag: String) {
        guard !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        tags = TagFieldPolicy.adding(tag, to: tags)
        query = ""
        highlighted = rows.isEmpty ? nil : 0
        isFocused = true
    }

    private func remove(_ tag: String) {
        tags = TagFieldPolicy.removing(tag, from: tags)
        highlighted = rows.isEmpty ? nil : 0
    }
}

// MARK: - Row view

private struct TagRowView: View {
    let row: TagFieldPolicy.Row
    let isHighlighted: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            switch row {
            case .existing(let tag):
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                Text(tag)
            case .create(let tag):
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                Text(TermindCopy.Vault.createNamed(tag))
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Highlight.fill(isSelected: isHighlighted, isHovering: isHovering),
            in: .rect(cornerRadius: Metrics.Radius.small)
        )
        .contentShape(.rect(cornerRadius: Metrics.Radius.small))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Chip

/// A chosen tag, with the ⓧ that takes it back off.
///
/// Not `CardChip` with an optional action bolted on: that one is read-only
/// decoration in five places, and the only thing the two share is a capsule.
/// The metrics are copied deliberately so the chip here and the chip on the
/// Hosts card read as the same object.
private struct RemovableTagChip: View {
    let tag: String
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.xxs) {
            Text(tag)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(TermindCopy.Vault.removeTag(tag)))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .lineLimit(1)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    @Previewable @State var tags = ["nginx", "prod"]

    Form {
        Section(TermindCopy.Vault.groupingAndTags.swiftUIKey) {
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                Text(TermindCopy.Vault.tags)
                TagField(tags: $tags, suggestions: HostLibraryModel.demo().allTags)
            }
        }
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 380)
}
