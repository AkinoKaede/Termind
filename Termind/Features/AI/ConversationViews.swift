import AppKit
import SwiftUI

// MARK: - Context chips

/// The row of user-visible attachments sent to the LLM endpoint.
///
/// This is the trust surface of the whole feature. BYOK means the user's own key
/// pays for — and is exposed to — whatever we upload. The setting-disclosed,
/// token-sanitized Shell Integration environment is not a chip.
///
/// Two sources, deliberately. Host and directory are pinned and come from the
/// *surface*; everything the user added by hand comes from the conversation and
/// can be taken back off. So a composer with no session — the Assistant tab,
/// which is handed `.none` — cannot show, or send, a host and directory it does
/// not have.
struct ContextChipsView: View {
    let sessionContext: SessionContext
    let conversation: ConversationModel

    var body: some View {
        FlowLayout(spacing: Metrics.Space.xs) {
            ForEach(sessionContext.chips) { chip in
                ChipView(chip: chip, remove: nil)
            }
            ForEach(conversation.attachments) { chip in
                ChipView(chip: chip) { conversation.detach(chip.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Attached session information"))
    }
}

private struct ChipView: View {
    let chip: ContextChip
    /// `nil` for a pinned session pill: the user's control over those is which
    /// pane has focus, not a per-turn checkbox.
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: chip.kind.symbol)
                .font(.caption2)
            Text(chip.label)
                .font(.caption)
                .lineLimit(1)
            if let remove {
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
        .help(Text(remove == nil ? "Always included" : "Remove attachment"))
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

// MARK: - Composer

/// The composer's rounded card, as a modifier.
///
/// Extracted because the slash palette stacks directly above the composer and is
/// meant to read as the same object. Two hand-written copies of the same six
/// lines drift the first time one radius changes, and the drift shows up as two
/// blocks in one column that are almost — but not quite — the same shape.
private struct ComposerBlock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Metrics.Space.l)
            .background(.bar, in: .rect(cornerRadius: Metrics.Chat.composerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Chat.composerRadius)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}

extension View {
    func composerBlock() -> some View { modifier(ComposerBlock()) }
}

/// The Plan chip, which exists only while plan mode is on.
///
/// Not a menu, and not a third picker beside the other two: it is a state the
/// composer is *in*, so it is drawn as an active badge and the only thing it can
/// do is stop. Turning it on is `/plan`, which keeps the resting composer
/// exactly as it was for anyone who never uses the mode.
///
/// Hovering swaps the glyph for an ✕, which is the affordance and the warning in
/// one: the chip is a button, and the button ends the mode.
private struct PlanModeChip: View {
    let compact: Bool
    let onExit: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onExit) {
            HStack(spacing: Metrics.Space.xs) {
                Image(systemName: isHovering ? "xmark" : PlanModeChip.symbol)
                    .contentTransition(.symbolEffect(.replace))
                    // Fixed, because the two glyphs are not the same width.
                    // Without it the swap resizes the chip under the pointer and
                    // shoves the label — and on a hover, movement reads as the
                    // control running away from the click.
                    .frame(width: Self.glyphWidth)
                if !compact {
                    Text("Plan")
                }
            }
            .font(.caption2)
            // The same grey as the permission chip and the transcribe button
            // beside it. Tinting it would make an active mode look like an
            // alert, and this is a posture, not a warning.
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text("Plan mode — click to turn off"))
        .accessibilityLabel(Text("Plan mode on, turn off"))
    }

    /// A lit bulb — the one drawn with rays, not the dark `lightbulb`. Planning
    /// is the idea before the work, and the same glyph carries the mode
    /// wherever it appears: this chip, the `/plan` row, and the plan itself in
    /// the transcript.
    static let symbol = "lightbulb.max"

    /// Wide enough for every glyph that shares this column at `.caption2` — the
    /// bulb's rays are wider than an `xmark`, and the ring beside it is wider
    /// still. Fixed so none of the swaps between them move anything.
    static let glyphWidth: CGFloat = 13
}

struct ComposerView: View {
    let conversation: ConversationModel
    var prompt: LocalizedStringKey = "Ask anything…"
    /// The full Assistant tab shares one centered column with its transcript.
    /// `nil` keeps compact/sidebar composers fluid.
    var maxContentWidth: CGFloat? = nil
    /// What the surface showing this composer knows about the focused pane.
    /// Defaulting to `.none` is what makes a composer outside a Workspace — the
    /// Assistant tab — session-free by construction rather than by remembering.
    var sessionContext: SessionContext = .none
    /// Only the Workspace sidebar gives its agent a command-card tool.
    var includesTerminalSuggestion = false
    var onSend: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var draftBeforeTranscription = ""
    @State private var slashSelection = 0
    @State private var slashMenuHeight: CGFloat = 0
    /// Escape closes the palette without clearing the draft, so the draft alone
    /// cannot decide whether it is open.
    @State private var isSlashMenuDismissed = false
    @State private var draftHeight = Metrics.Chat.compactComposerMinHeight

    private var resolved: (provider: ModelProvider, model: AIModel)? {
        app.aiConfiguration.resolve(conversation: conversation.model)
    }

    private var modelProviders: [ModelProvider] {
        app.aiConfiguration.enabledModelProviders.filter { !$0.chatModels.isEmpty }
    }

    private var resolvedModelLabel: String {
        resolved?.model.label ?? String(localized: "No model")
    }

    private var resolvedPermissionMode: ChatPermissionMode {
        app.aiConfiguration.resolve(conversation: conversation.permissionMode)
    }

    private var reasoningResolution: ModelCapabilityResolver.ReasoningResolution? {
        guard let resolved else { return nil }
        return ModelCapabilityResolver.reasoning(model: resolved.model, provider: resolved.provider)
    }

    private var effectiveReasoningEffort: ReasoningEffort {
        reasoningResolution?.clamp(conversation.reasoningEffort) ?? .off
    }

    private var supportsThinking: Bool {
        reasoningResolution?.supported.contains(where: { $0 != .off }) == true
    }

    private var transcription: SpeechTranscriptionCoordinator {
        app.speechTranscription
    }

    private var ownsTranscription: Bool {
        transcription.isOwned(by: conversation.id)
    }

    private var showsTranscriptionControls: Bool {
        ownsTranscription && transcription.phase != .idle
    }

    var body: some View {
        @Bindable var conversation = conversation

        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !sessionContext.isEmpty || !conversation.attachments.isEmpty {
                ContextChipsView(sessionContext: sessionContext, conversation: conversation)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            draftEditor($conversation.draft)

            ZStack {
                if showsTranscriptionControls {
                    transcriptionControls
                        .transition(.opacity)
                } else {
                    standardControls
                        .transition(.opacity)
                }
            }
            // Both modes occupy the same bottom toolbar slot. Recording must
            // never replace or vertically relocate the draft editor.
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .animation(Motion.panel(reduceMotion: reduceMotion), value: showsTranscriptionControls)
        }
        .composerBlock()
        // Anchored inside the block, before the horizontal inset and the width
        // caps, so the palette inherits the block's exact edges rather than
        // restating them. See `SlashCommandMenuView`.
        .overlay(alignment: .top) {
            slashMenu
        }
        .padding(.horizontal, Metrics.Space.l)
        .frame(maxWidth: maxContentWidth ?? .infinity)
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.Space.s)
        .padding(
            .bottom,
            maxContentWidth == nil ? Metrics.Space.s : Metrics.Space.l
        )
        .onAppear(perform: normalizeReasoningEffort)
        .onChange(of: reasoningResolution) { _, _ in normalizeReasoningEffort() }
        .onDisappear {
            guard transcription.isOwned(by: conversation.id) else { return }
            conversation.draft = draftBeforeTranscription
            transcription.cancel(ownerID: conversation.id)
        }
        .alert(
            transcriptionError?.title ?? String(localized: "Transcription Failed"),
            isPresented: transcriptionErrorPresented
        ) {
            if transcriptionError?.offersSystemSettings == true {
                Button("Open System Settings") { openTranscriptionPrivacySettings() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if let error = transcriptionError {
                Text(error.message)
            }
        }
    }

    /// The draft field, sized by what is in it.
    ///
    /// The height comes from a hidden twin of the draft laid out at its own
    /// ideal size, because `TextEditor` will not report one: given a range it
    /// takes the top of the range, which is why an empty composer used to be as
    /// tall as a five-line one. Measuring a `Text` instead means the box starts
    /// at one comfortable line and grows only as the draft does.
    private func draftEditor(_ draft: Binding<String>) -> some View {
        ZStack(alignment: .topLeading) {
            Text(draft.wrappedValue.isEmpty ? " " : draft.wrappedValue)
                .font(.body)
                .padding(.leading, Self.editorTextInset)
                .padding(.vertical, Metrics.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Ignores the height it is offered and reports its own, which
                // is what keeps this out of a measurement loop.
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { draftHeight = $0 }

            TextEditor(text: draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .overlay(alignment: .topLeading) {
                    if draft.wrappedValue.isEmpty {
                        Text(prompt)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, Self.editorTextInset)
                            .allowsHitTesting(false)
                    }
                }
                // Before Return, so an open palette gets first refusal on the
                // keys that drive it. Each handler declines when the palette is
                // closed, which is what leaves ordinary editing untouched.
                .onKeyPress(.upArrow, phases: .down) { _ in
                    moveSlashSelection(by: -1) ? .handled : .ignored
                }
                .onKeyPress(.downArrow, phases: .down) { _ in
                    moveSlashSelection(by: 1) ? .handled : .ignored
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    acceptHighlightedSlashRow() ? .handled : .ignored
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    guard !slashCompletion.isEmpty else { return .ignored }
                    // Closes the palette, keeps the draft. Someone who typed
                    // `/compact keep the nginx findings` and wants the menu out
                    // of the way has not asked to lose the sentence.
                    isSlashMenuDismissed = true
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    let disallowed: EventModifiers = [.control, .option]
                    guard press.modifiers.intersection(disallowed).isEmpty else { return .ignored }
                    if acceptHighlightedSlashRow() { return .handled }
                    sendDraft()
                    return .handled
                }
                // Typing again after Escape re-opens the palette; the dismissal
                // was about one keystroke, not about the rest of the draft.
                .onChange(of: conversation.draft) { _, _ in
                    isSlashMenuDismissed = false
                }
                // The Stop button gives its slot to Send as soon as the draft
                // has a character in it — which is exactly when this field has
                // focus. Without this, typing would make a run unstoppable
                // until the draft was cleared again.
                .onKeyPress(KeyEquivalent("."), phases: .down) { press in
                    guard conversation.isStreaming, press.modifiers.contains(.command) else {
                        return .ignored
                    }
                    conversation.stop()
                    return .handled
                }
        }
        .frame(
            height: min(
                max(draftHeight, minimumDraftHeight),
                Metrics.Chat.composerMaxHeight
            )
        )
    }

    private var minimumDraftHeight: CGFloat {
        maxContentWidth == nil
            ? Metrics.Chat.compactComposerMinHeight
            : Metrics.Chat.composerMinHeight
    }

    /// `TextEditor`'s own leading text-container inset, which the placeholder
    /// and the measuring twin both have to match or the text jumps sideways
    /// when the field gains content.
    private static let editorTextInset: CGFloat = 5

    private var trimmedDraft: String {
        conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop and Send share one slot rather than standing side by side.
    ///
    /// Drawn together they read as a pair of equals, and the primary action
    /// moved under the pointer the moment the draft gained a character. With a
    /// draft to send, Send is what the button is for; with nothing to send,
    /// stopping is the only thing left to do.
    private var showsStopButton: Bool { conversation.isStreaming && trimmedDraft.isEmpty }

    private var standardControls: some View {
        HStack(spacing: Metrics.Space.s) {
            ViewThatFits(in: .horizontal) {
                composerMenus(compact: false)
                composerMenus(compact: true)
            }
            .frame(maxWidth: .infinity)

            transcribeButton
            if showsStopButton {
                stopButton
            } else {
                sendButton(
                    enabled: !trimmedDraft.isEmpty,
                    help: conversation.isStreaming
                        ? "Queue for the running agent — ⏎" : "Send — ⌘⏎",
                    action: sendDraft
                )
            }
        }
        .animation(Motion.panel(reduceMotion: reduceMotion), value: showsStopButton)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
    }

    private var stopButton: some View {
        Button(action: conversation.stop) {
            Label("Stop", systemImage: "stop.circle.fill")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.red)
        .frame(width: 32, height: 32)
        .contentShape(.circle)
        .help(Text("Stop current run — ⌘."))
    }

    private var transcribeButton: some View {
        Button(action: beginTranscription) {
            Group {
                if ownsTranscription && transcription.isRequestingAuthorization {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "mic")
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .disabled(
            !transcription.canStart(for: conversation.id)
                || (ownsTranscription && transcription.isRequestingAuthorization)
        )
        .help(Text("Transcribe with Apple Speech"))
        .accessibilityLabel(Text("Transcribe"))
    }

    @ViewBuilder
    private var transcriptionControls: some View {
        switch transcription.phase {
        case .recording:
            HStack(spacing: Metrics.Space.m) {
                circularControl(
                    title: "Cancel Transcription",
                    systemImage: "xmark",
                    action: cancelTranscription
                )

                SpeechWaveformView(
                    samples: transcription.levelSamples,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: .infinity, minHeight: 32)
                .accessibilityLabel(Text("Recording"))

                circularControl(
                    title: "Stop Recording",
                    systemImage: "stop.fill",
                    action: { transcription.stop(ownerID: conversation.id) }
                )

                sendButton(
                    enabled: true,
                    action: {
                        transcription.stop(
                            ownerID: conversation.id,
                            sendAfterTranscription: true
                        )
                    }
                )
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        case .transcribing:
            HStack(spacing: Metrics.Space.m) {
                circularControl(
                    title: "Cancel Transcription",
                    systemImage: "xmark",
                    action: cancelTranscription
                )

                Spacer(minLength: Metrics.Space.s)
                Text("Transcribing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: Metrics.Space.s)

                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.55), in: .circle)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text("Transcribing"))

                sendButton(enabled: false, action: {})
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        case .idle:
            EmptyView()
        }
    }

    private func sendButton(
        enabled: Bool,
        help: LocalizedStringKey = "Send — ⌘⏎",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label("Send", systemImage: "arrow.up.circle.fill")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 26, weight: .semibold))
        .frame(width: 32, height: 32)
        .contentShape(.circle)
        .disabled(!enabled)
        .help(Text(help))
    }

    private func circularControl(
        title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.55), in: .circle)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }

    private var transcriptionError: SpeechTranscriptionFailure? {
        guard transcription.errorOwnerID == conversation.id else { return nil }
        return transcription.error
    }

    private var transcriptionErrorPresented: Binding<Bool> {
        Binding(
            get: { transcriptionError != nil },
            set: { presented in
                if !presented { transcription.dismissError(ownerID: conversation.id) }
            }
        )
    }

    private func beginTranscription() {
        draftBeforeTranscription = conversation.draft
        Task {
            await transcription.start(ownerID: conversation.id) { transcript, shouldSend in
                let applied = conversation.applyTranscription(
                    transcript,
                    sendAfterTranscription: shouldSend,
                    send: sendDraft
                )
                if applied { isFocused = true }
            }
        }
    }

    private func cancelTranscription() {
        conversation.draft = draftBeforeTranscription
        transcription.cancel(ownerID: conversation.id)
        isFocused = true
    }

    private func sendDraft() {
        // First, and before the streaming check: a command is not a message, so
        // it is not queued at a busy agent either. `/reasoning high` mid-run
        // changes the next request, which is exactly when someone would type it.
        if runSlashCommand() { return }
        if conversation.isStreaming {
            conversation.submitSteeringDraft()
            return
        }
        if let onSend {
            onSend()
        } else {
            app.sendAgentDraft(
                conversation, context: sessionContext,
                includesTerminalSuggestion: includesTerminalSuggestion
            )
        }
    }

    private func openTranscriptionPrivacySettings() {
        let anchor =
            transcriptionError?.code == .speechPermissionDenied
            ? "Privacy_SpeechRecognition"
            : "Privacy_Microphone"
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Slash commands

    /// What this conversation offers. `/reasoning` only where the resolved model
    /// has more than one effort to choose between — a command that can only
    /// confirm what is already true is a row that wastes the reader's time.
    private var slashCommands: [ChatSlashCommand] {
        var commands: [ChatSlashCommand] = [
            ChatSlashCommand(
                id: "plan",
                summary: conversation.isPlanning
                    ? String(localized: "Stop planning and act")
                    : String(localized: "Research and propose before acting"),
                icon: .symbol(PlanModeChip.symbol),
                // Free text, so `/plan why is root at 99%` both enters the mode
                // and asks the question. Typing `/plan` alone toggles it.
                argumentHint: String(localized: "what to plan")
            )
        ]
        // Always listed, whether or not there is enough history to act on.
        // Gating this on the compaction threshold hid it in every ordinary
        // conversation — a command that appears only once you are near the
        // context limit is one nobody knows exists, and the ring beside it is
        // worth seeing regardless. Running it early says so rather than doing
        // nothing.
        commands.append(ChatSlashCommand(
            id: "compact",
            summary: String(localized: "Summarize older turns to free context"),
            icon: .contextRing,
            argumentHint: String(localized: "what to emphasize")
        ))
        if supportsThinking {
            commands.append(ChatSlashCommand(
                id: "reasoning",
                summary: String(localized: "How hard the model thinks"),
                icon: .symbol("brain"),
                argumentHint: String(localized: "effort")
            ))
        }
        return commands
    }

    private var slashOptions: (ChatSlashCommand) -> [ChatSlashCommand.Option] {
        { command in
            guard command.id == "reasoning", let reasoningResolution else { return [] }
            return reasoningResolution.supported.map { effort in
                ChatSlashCommand.Option(id: effort.rawValue, label: effort.displayName)
            }
        }
    }

    private var slashCompletion: ChatSlashCommandCompletion {
        guard !isSlashMenuDismissed else { return ChatSlashCommandCompletion(rows: []) }
        return ChatSlashCommandCompletion.rows(
            draft: conversation.draft, commands: slashCommands, options: slashOptions
        )
    }

    @ViewBuilder
    private var slashMenu: some View {
        let completion = slashCompletion
        if !completion.isEmpty {
            SlashCommandMenuView(
                completion: completion,
                selection: min(slashSelection, completion.rows.count - 1),
                contextShare: contextShare,
                trailingText: slashTrailingText,
                onHover: { slashSelection = $0 },
                onSelect: acceptSlashRow
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                slashMenuHeight = $0
            }
            // Lifted clear of the block it is anchored to. Measured rather than
            // guessed, because the height is the row count.
            .offset(y: -(slashMenuHeight + Metrics.Space.s))
            .transition(.opacity)
        }
    }

    private func slashTrailingText(_ row: ChatSlashCommandCompletion.Row) -> String? {
        switch row {
        case .command(let command) where command.id == "reasoning":
            return effectiveReasoningEffort.displayName
        case .option(let command, let option) where command.id == "reasoning":
            return option.id == effectiveReasoningEffort.rawValue
                ? String(localized: "Current") : nil
        default:
            return nil
        }
    }

    /// Completing a name leaves the draft in the field; running a command clears
    /// it. The difference is whether there is anything left to choose.
    private func acceptSlashRow(_ row: ChatSlashCommandCompletion.Row) {
        switch row {
        case .command(let command):
            // Advance to a second palette page only when there is one. Free text
            // — `/plan <question>`, `/compact <instructions>` — is typed, not
            // chosen, so a command that takes it still runs on Return and the
            // argument is for whoever wants to type one.
            let hasOptions = !slashOptions(command).isEmpty
            conversation.draft = ChatSlashCommandCompletion.accepted(
                row, takesArgument: hasOptions
            )
            slashSelection = 0
            if !hasOptions { runSlashCommand() }
        case .option:
            conversation.draft = ChatSlashCommandCompletion.accepted(row, takesArgument: false)
            slashSelection = 0
            runSlashCommand()
        }
    }

    /// Runs whatever the draft names, and reports whether it did.
    ///
    /// A command never becomes a turn: nothing reaches `messages` or
    /// `transcript`, so the model is never shown `/reasoning high` as something
    /// the user said to it.
    @discardableResult
    private func runSlashCommand() -> Bool {
        guard let input = ChatSlashCommandInput.parse(conversation.draft),
            let command = slashCommands.first(where: { $0.id == input.name.lowercased() })
        else { return false }

        switch command.id {
        case "plan":
            // The one command that runs on its bare name: `/plan` toggles the
            // mode, and `/plan <question>` turns it on and asks. Both are the
            // whole action, so neither leaves a half-typed command behind.
            let question = argumentText(of: input)
            guard question.isEmpty else {
                conversation.isPlanning = true
                clearSlashDraft()
                conversation.draft = question
                sendDraft()
                return true
            }
            conversation.isPlanning.toggle()
        case "compact":
            let instructions = argumentText(of: input)
            clearSlashDraft()
            Task { await app.compact(conversation, instructions: instructions) }
            return true
        case "reasoning":
            guard case .argument(_, let argument) = input else { return false }
            guard let effort = ReasoningEffort(rawValue: argument.lowercased()),
                reasoningResolution?.supported.contains(effort) == true
            else { return false }
            conversation.reasoningEffort = effort
        default:
            return false
        }
        clearSlashDraft()
        return true
    }

    private func argumentText(of input: ChatSlashCommandInput) -> String {
        guard case .argument(_, let text) = input else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearSlashDraft() {
        conversation.draft = ""
        isSlashMenuDismissed = false
        slashSelection = 0
    }

    /// Accepts what the palette is highlighting, if it is showing anything.
    private func acceptHighlightedSlashRow() -> Bool {
        let completion = slashCompletion
        guard !completion.isEmpty else { return false }
        let index = min(slashSelection, completion.rows.count - 1)
        acceptSlashRow(completion.rows[index])
        return true
    }

    private func moveSlashSelection(by delta: Int) -> Bool {
        let count = slashCompletion.rows.count
        guard count > 0 else { return false }
        slashSelection = (min(slashSelection, count - 1) + delta + count) % count
        return true
    }

    private func composerMenus(compact: Bool) -> some View {
        HStack(spacing: Metrics.Space.s) {
            permissionMenu(compact: compact)
            if conversation.isPlanning {
                PlanModeChip(compact: compact) { conversation.isPlanning = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Spacer(minLength: Metrics.Space.s)
            modelAndThinkingMenu(compact: compact)
        }
        .animation(Motion.panel(reduceMotion: reduceMotion), value: conversation.isPlanning)
    }

    private func permissionMenu(compact: Bool) -> some View {
        Menu {
            ForEach(ChatPermissionMode.allCases) { mode in
                Button {
                    conversation.permissionMode = mode
                    app.aiConfiguration.select(mode)
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

    private var contextEstimate: AgentContextEstimate {
        conversation.contextEstimate
    }

    private var contextShare: Double? {
        // No window, no ring. A gateway that does not report `contextLength`
        // leaves us with a numerator and no denominator, and a ring drawn on a
        // guessed window would be a confident picture of nothing.
        guard contextEstimate.total > 0 else { return nil }
        return contextEstimate.share(of: resolved?.model.contextLength)
    }

    private func modelAndThinkingMenu(compact: Bool) -> some View {
        Menu {
            if contextEstimate.total > 0 {
                ContextBreakdownMenuItems(
                    estimate: contextEstimate,
                    contextWindow: resolved?.model.contextLength,
                    cachedInputTokens: conversation.usage?.cachedInputTokens ?? 0
                )
            }

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

            if supportsThinking, let reasoningResolution {
                Menu("Thinking") {
                    ForEach(reasoningResolution.supported) { effort in
                        Button {
                            conversation.reasoningEffort = effort
                        } label: {
                            selectionLabel(
                                effort.displayName,
                                isSelected: effort == effectiveReasoningEffort
                            )
                        }
                    }
                }
            }
        } label: {
            if compact {
                modelGlyph
                    .font(.caption)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    modelGlyph
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

    /// The ring once there is something to weigh, `sparkles` until then.
    ///
    /// Replacing the glyph rather than adding a second one: the row is already
    /// four controls wide at 260pt, and a conversation's size is a property of
    /// the model it is being sent to, which is what this menu is about.
    @ViewBuilder
    private var modelGlyph: some View {
        Group {
            if let contextShare {
                ContextRing(share: contextShare)
            } else {
                Image(systemName: "sparkles")
            }
        }
        // One column for both. The ring arrives the moment the first turn
        // reports its usage, and a glyph that changed width at that moment
        // would shift the model name sideways mid-reply.
        .frame(width: PlanModeChip.glyphWidth)
    }

    private var modelAndThinkingLabel: String {
        guard resolved != nil, supportsThinking else { return resolvedModelLabel }
        return "\(resolvedModelLabel) · \(effectiveReasoningEffort.displayName)"
    }

    private var modelAndThinkingAccessibilityLabel: String {
        guard resolved != nil else { return String(localized: "Model, no model configured") }
        guard supportsThinking else { return String(localized: "Model \(resolvedModelLabel)") }
        return String(
            localized: "Model \(resolvedModelLabel), thinking \(effectiveReasoningEffort.displayName)"
        )
    }

    private var modelAndThinkingHelp: String {
        if let resolved {
            guard supportsThinking else {
                return String(localized: "\(resolved.model.label) through \(resolved.provider.name)")
            }
            return String(
                localized:
                    "\(resolved.model.label) through \(resolved.provider.name) · \(effectiveReasoningEffort.displayName) thinking"
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
        app.aiConfiguration.select(ref)
        let resolution = ModelCapabilityResolver.reasoning(model: model, provider: provider)
        conversation.reasoningEffort = resolution.clamp(conversation.reasoningEffort)
    }

    private func normalizeReasoningEffort() {
        let normalized = effectiveReasoningEffort
        if conversation.reasoningEffort != normalized {
            conversation.reasoningEffort = normalized
        }
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

private struct SpeechWaveformView: View {
    let samples: [Float]
    let reduceMotion: Bool

    private var displayedSamples: [Float] {
        reduceMotion ? Array(repeating: 0.18, count: samples.count) : samples
    }

    var body: some View {
        Canvas { context, size in
            let values = displayedSamples
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(max(values.count - 1, 1))

            for (index, rawValue) in values.enumerated() {
                let value = CGFloat(min(max(rawValue, 0.04), 1))
                let diameter = 2.2 + value * 3.8
                let rect = CGRect(
                    x: CGFloat(index) * step - diameter / 2,
                    y: size.height / 2 - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.primary.opacity(0.16 + value * 0.64))
                )
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: samples)
    }
}
