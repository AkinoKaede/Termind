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
        FlowLayout(spacing: Metrics.Space.xs) {
            ForEach(conversation.contextChips) { chip in
                ChipView(chip: chip) { conversation.removeChip(chip.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Attached session information"))
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
        .help(Text(chip.isRemovable ? "Remove attachment" : "Always included"))
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
            let naturalSize = subview.sizeThatFits(.unspecified)
            // A cwd can be wider than the compact 260pt Assistant sidebar.
            // Place it with a bounded proposal so the chip truncates instead of
            // pushing the composer controls off screen.
            let size = CGSize(width: min(naturalSize.width, width), height: naturalSize.height)
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
    var prompt: LocalizedStringKey = "Ask anything…"
    var onSend: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFocused: Bool

    private var resolved: (provider: ModelProvider, model: AIModel)? {
        app.ai.resolve(conversation: conversation.model)
    }

    private var modelProviders: [ModelProvider] {
        app.ai.enabledModelProviders.filter { !$0.chatModels.isEmpty }
    }

    private var resolvedModelLabel: String {
        resolved?.model.label ?? String(localized: "No model")
    }

    private var resolvedPermissionMode: ChatPermissionMode {
        app.ai.resolve(conversation: conversation.permissionMode)
    }

    var body: some View {
        @Bindable var conversation = conversation

        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !conversation.contextChips.isEmpty {
                ContextChipsView(conversation: conversation)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            TextEditor(text: $conversation.draft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 46, maxHeight: 120)
                .focused($isFocused)
                .overlay(alignment: .topLeading) {
                    if conversation.draft.isEmpty {
                        Text(prompt)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: Metrics.Space.s) {
                ViewThatFits(in: .horizontal) {
                    composerMenus(compact: false)
                    composerMenus(compact: true)
                }
                .frame(maxWidth: .infinity)

                Button {
                    if let onSend {
                        onSend()
                    } else {
                        conversation.sendDraft()
                    }
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

    private func composerMenus(compact: Bool) -> some View {
        HStack(spacing: Metrics.Space.s) {
            permissionMenu(compact: compact)
            Spacer(minLength: Metrics.Space.s)
            modelAndThinkingMenu(compact: compact)
        }
    }

    private func permissionMenu(compact: Bool) -> some View {
        Menu {
            ForEach(ChatPermissionMode.allCases) { mode in
                Button {
                    conversation.permissionMode = mode
                    app.ai.select(mode)
                } label: {
                    selectionLabel(mode.displayName, isSelected: mode == resolvedPermissionMode)
                }
            }
        } label: {
            if compact {
                Image(systemName: resolvedPermissionMode.symbol)
                    .font(.caption)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(permissionTint)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    Image(systemName: resolvedPermissionMode.symbol)
                        .symbolRenderingMode(.monochrome)
                    Text(resolvedPermissionMode.displayName)
                }
                    .font(.caption2)
                    .foregroundStyle(permissionTint)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .tint(permissionTint)
        .fixedSize()
        .help(Text("Permission: \(resolvedPermissionMode.displayName)"))
        .accessibilityLabel(Text("Permission, \(resolvedPermissionMode.displayName)"))
    }

    private var permissionTint: Color {
        resolvedPermissionMode == .fullAccess ? .red : .secondary
    }

    private func modelAndThinkingMenu(compact: Bool) -> some View {
        Menu {
            Menu("Model") {
                if modelProviders.isEmpty {
                    Text("No models configured")
                        .disabled(true)
                    Divider()
                } else {
                    ForEach(modelProviders) { provider in
                        Section(provider.name) {
                            ForEach(provider.chatModels) { model in
                                Button {
                                    select(model, on: provider)
                                } label: {
                                    selectionLabel(
                                        model.label,
                                        isSelected: isSelected(model, on: provider)
                                    )
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button("Configure Model Providers") { openSettings() }
            }

            if resolved != nil {
                Menu("Thinking") {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Button {
                            conversation.reasoningEffort = effort
                        } label: {
                            selectionLabel(
                                effort.displayName,
                                isSelected: effort == conversation.reasoningEffort
                            )
                        }
                    }
                }
            }
        } label: {
            if compact {
                Image(systemName: "sparkles")
                    .font(.caption)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                    Text(modelAndThinkingLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(Text(modelAndThinkingHelp))
        .accessibilityLabel(Text(modelAndThinkingAccessibilityLabel))
    }

    private var modelAndThinkingLabel: String {
        guard resolved != nil else { return resolvedModelLabel }
        return "\(resolvedModelLabel) · \(conversation.reasoningEffort.displayName)"
    }

    private var modelAndThinkingAccessibilityLabel: String {
        guard resolved != nil else { return String(localized: "Model, no model configured") }
        return String(
            localized: "Model \(resolvedModelLabel), thinking \(conversation.reasoningEffort.displayName)"
        )
    }

    private var modelAndThinkingHelp: String {
        if let resolved {
            return String(
                localized:
                    "\(resolved.model.label) through \(resolved.provider.name) · \(conversation.reasoningEffort.displayName) thinking"
            )
        }
        return String(localized: "No model configured")
    }

    private func isSelected(_ model: AIModel, on provider: ModelProvider) -> Bool {
        resolved?.provider.id == provider.id && resolved?.model.id == model.id
    }

    /// Sets this conversation's model and records the same choice as the
    /// app-wide fallback for conversations that have not chosen one.
    private func select(_ model: AIModel, on provider: ModelProvider) {
        let ref = AIModelRef(modelProviderID: provider.id, modelID: model.id)
        conversation.model = ref
        app.ai.select(ref)
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
