import SwiftUI

// MARK: - Context chips

/// The row of chips showing exactly what will be sent to the LLM endpoint.
///
/// This is the trust surface of the whole feature. BYOK means the user's own key
/// pays for — and is exposed to — whatever we upload, so the rule is that nothing
/// leaves the machine unless it is visible here. Host and directory are pinned;
/// everything else the user added by hand can be taken back off.
struct ContextChipsView: View {
    let conversation: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack {
                Text("Context")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("~\(conversation.estimatedContextTokens) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                addMenu
            }

            FlowLayout(spacing: Metrics.Space.xs) {
                ForEach(conversation.contextChips) { chip in
                    ChipView(chip: chip) { conversation.removeChip(chip.id) }
                }
            }
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
    }

    private var addMenu: some View {
        Menu {
            Button("Last 200 Lines") {
                conversation.addChip(
                    ContextChip(kind: .output, label: String(localized: "Last 200 lines"), approximateTokens: 1_450)
                )
            }
            Button("Terminal Selection") {
                conversation.addChip(
                    ContextChip(kind: .selection, label: String(localized: "Selection"), approximateTokens: 120)
                )
            }
            Button("File") {}
                .disabled(true)
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Attach context"))
    }
}

private struct ChipView: View {
    let chip: ContextChip
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: chip.kind.symbol)
                .font(.caption2)
            Text(chip.label)
                .font(.caption)
                .lineLimit(1)
            if chip.isRemovable {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .help(Text(chip.isRemovable ? "Remove from context" : "Always included"))
    }
}

/// Wraps chips onto as many lines as they need. `HStack` would clip them and
/// `LazyVGrid` would force a column width that fits the longest path.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews: subviews, in: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var items: [(index: Int, x: CGFloat, size: CGSize)]
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, !current.items.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing, height: 0, items: [])
                x = 0
            }
            current.items.append((index, x, size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Messages

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: message.role == .user ? "person.crop.circle" : "sparkles")
                    .foregroundStyle(message.role == .user ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }

            Text(markdown(message.text))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(message.commands) { command in
                CommandCardView(command: command)
            }
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? AnyShapeStyle(.quaternary.opacity(0.25)) : AnyShapeStyle(.clear))
    }

    /// Inline markdown only — full block rendering (lists, tables, fenced code)
    /// arrives with P3, where streaming makes partial-parse handling necessary
    /// anyway.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Composer

struct ComposerView: View {
    let conversation: ConversationModel

    @Environment(AppModel.self) private var app
    @FocusState private var isFocused: Bool

    private var resolvedModelLabel: String {
        app.ai.resolve(conversation: conversation.model)?.model.label ?? String(localized: "No model")
    }

    var body: some View {
        @Bindable var conversation = conversation

        VStack(spacing: Metrics.Space.s) {
            TextEditor(text: $conversation.draft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 46, maxHeight: 120)
                .focused($isFocused)
                .overlay(alignment: .topLeading) {
                    if conversation.draft.isEmpty {
                        Text("Ask about this session…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: Metrics.Space.s) {
                // Resolved the same way `ModelProviderBar` resolves it — an unset
                // conversation shows the Chat role's answer rather than a blank.
                Text(resolvedModelLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    conversation.sendDraft()
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title2)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(Text("Send — ⌘⏎"))
            }
        }
        .padding(Metrics.Space.l)
        .background(.bar)
    }
}
