import AppKit
import ListViewKit
import SwiftUI
import UniformTypeIdentifiers

/// Reports composition text that SwiftUI's String binding has not committed.
/// The observer lives beside the TextEditor and follows the field editor in
/// the same window, so Pinyin candidates hide the hint before they are put into
/// the bound draft.
struct TextViewMarkedTextObserver: NSViewRepresentable {
    @Binding var hasMarkedText: Bool
    var paste: () -> Bool = { false }

    final class ObserverView: NSView {
        var report: (Bool) -> Void = { _ in }
        var paste: () -> Bool = { false }
        private var monitors: [any NSObjectProtocol] = []
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDown()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [
                NSText.didBeginEditingNotification,
                NSText.didChangeNotification,
                NSText.didEndEditingNotification,
            ] {
                monitors.append(
                    center.addObserver(
                        forName: name, object: nil, queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.refresh() }
                    })
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
                [weak self, weak window] event in
                guard event.window === window else { return event }
                if event.type == .keyDown, event.modifierFlags.contains(.command),
                    event.charactersIgnoringModifiers?.lowercased() == "v",
                    self?.paste() == true
                {
                    return nil
                }
                DispatchQueue.main.async { self?.refresh() }
                return event
            }
            refresh()
        }

        private func refresh() {
            let marked = (window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            report(marked)
        }

        private func tearDown() {
            let center = NotificationCenter.default
            monitors.forEach(center.removeObserver)
            monitors.removeAll()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        func stop() { tearDown() }
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.report = update
        view.paste = paste
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.report = update
        nsView.paste = paste
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stop()
    }

    private func update(_ value: Bool) {
        guard hasMarkedText != value else { return }
        hasMarkedText = value
    }
}

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
    var cancelPending: (PendingContextAttachment.ID) -> Void = { _ in }

    var body: some View {
        FlowLayout(spacing: Metrics.Space.xs) {
            ForEach(sessionContext.chips) { chip in
                ChipView(chip: chip, remove: nil)
            }
            ForEach(conversation.attachments) { chip in
                ChipView(chip: chip) { conversation.detach(chip.id) }
            }
            ForEach(conversation.pendingAttachments) { pending in
                PendingChipView(pending: pending) {
                    cancelPending(pending.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Attached context"))
    }
}

private struct ChipView: View {
    let chip: ContextChip
    /// `nil` for a pinned session pill: the user's control over those is which
    /// pane has focus, not a per-turn checkbox.
    let remove: (() -> Void)?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let remove {
                Button(action: remove) { styledContent(removable: true) }
                    .buttonStyle(.plain)
                    .onHover { isHovering = $0 }
                    .focused($isFocused)
                    .accessibilityLabel(Text("Remove \(chip.label)"))
            } else {
                styledContent(removable: false)
            }
        }
        .help(Text(
            remove == nil
                ? String(localized: "Always included") : String(localized: "Remove attachment")
        ))
    }

    private func styledContent(removable: Bool) -> some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(
                systemName: removable && (isHovering || isFocused)
                    ? "xmark" : chip.kind.symbol
            )
                .font(.caption2)
                .frame(width: 12, height: 12)
                .contentTransition(.symbolEffect(.replace))
            Text(chip.label).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .contentShape(.capsule)
    }
}

private struct PendingChipView: View {
    let pending: PendingContextAttachment
    let cancel: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: cancel) {
            HStack(spacing: Metrics.Space.xs) {
                if isHovering || isFocused {
                    Image(systemName: "xmark").font(.caption2)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(pending.label).font(.caption).lineLimit(1)
            }
            .frame(minHeight: 12)
            .padding(.horizontal, Metrics.Space.s)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help(Text("Cancel import"))
        .accessibilityLabel(Text("Cancel importing \(pending.label)"))
    }
}

/// Wraps chips onto as many lines as they need. `HStack` would clip them and
/// `LazyVGrid` would force a column width that fits the longest path.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var fillsWidth = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.enumerated().reduce(CGFloat.zero) { total, item in
            total + item.element.sizeThatFits(.unspecified).width
                + (item.offset == 0 ? 0 : spacing)
        }
        let width = proposal.width ?? naturalWidth
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map { row in
            row.items.last.map { $0.x + $0.size.width } ?? 0
        }.max() ?? 0
        return CGSize(width: fillsWidth ? width : usedWidth, height: height)
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
/// Which column the interaction surface is in. It no longer changes what the
/// surface is *made of* — both are system glass — only how much room it has.
enum AssistantInteractionSurfaceStyle {
    case standard
    case sidebar
}

/// The one interactive surface in the Assistant column.
///
/// Composer, Steering and the archived-conversation notice are the same object
/// seen three times, so they share a radius, a material and a tint rather than
/// each drawing its own. Steering used to paint an opaque `.bar` with a
/// hand-drawn stroke directly above a Composer made of system glass, which read
/// as two unrelated panels stacked by accident.
private struct AssistantInteractionSurface: ViewModifier {
    let style: AssistantInteractionSurfaceStyle
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content
            .padding(Metrics.Space.l)
            // Untinted. The sidebar copy used to carry a grey wash to separate
            // it from the column behind, which is a job system glass already
            // does — and the wash was enough to make the composer read as a
            // flat box with a sheen rather than as glass.
            .termindGlassSurface(
                cornerRadius: Metrics.Chat.composerRadius,
                isInteractive: isEmphasized
            )
    }
}

extension View {
    func assistantInteractionSurface(
        style: AssistantInteractionSurfaceStyle = .standard,
        isEmphasized: Bool = false
    ) -> some View {
        modifier(
            AssistantInteractionSurface(
                style: style,
                isEmphasized: isEmphasized
            )
        )
    }

    /// The composer's own name for the shared surface, kept so the call sites
    /// that mean "this is the composer block" still read that way.
    func composerBlock(
        style: AssistantInteractionSurfaceStyle = .standard,
        isEmphasized: Bool = false
    ) -> some View {
        assistantInteractionSurface(style: style, isEmphasized: isEmphasized)
    }
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
    private enum ModelPickerSection {
        case model
        case thinking
    }

    let conversation: ConversationModel
    var prompt: LocalizedStringKey = "Ask anything…"
    var surfaceStyle: AssistantInteractionSurfaceStyle = .standard
    /// The full Assistant tab shares one centered column with its transcript.
    /// `nil` keeps compact/sidebar composers fluid.
    var maxContentWidth: CGFloat? = nil
    /// What the surface showing this composer knows about the focused pane.
    /// Defaulting to `.none` is what makes a composer outside a Workspace — the
    /// Assistant tab — session-free by construction rather than by remembering.
    var sessionContext: SessionContext = .none
    /// Only the Workspace sidebar gives its agent a command-card tool.
    var includesTerminalSuggestion = false
    var onNewChat: (() -> Void)?
    var onSend: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var draftBeforeTranscription = ""
    @State private var slashSelection = 0
    @State private var slashScrollRequest = 0
    @State private var slashMenuHeight: CGFloat = 0
    /// Escape closes the palette without clearing the draft, so the draft alone
    /// cannot decide whether it is open.
    @State private var isSlashMenuDismissed = false
    @State private var draftHeight = Metrics.Chat.compactComposerMinHeight
    @State private var hasMarkedText = false
    @State private var isPermissionPickerPresented = false
    @State private var isModelPickerPresented = false
    @State private var expandedModelPickerSection: ModelPickerSection?
    @State private var isDropTargeted = false
    @State private var attachmentTasks: [PendingContextAttachment.ID: Task<Void, Never>] = [:]

    private var resolved: (provider: ModelProvider, model: AIModel)? {
        app.aiConfiguration.resolve(conversation: conversation.model)
    }

    private var modelProviders: [ModelProvider] {
        app.aiConfiguration.enabledModelProviders.filter { !$0.assistantModels.isEmpty }
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
            if !sessionContext.isEmpty || !conversation.attachments.isEmpty
                || !conversation.pendingAttachments.isEmpty
            {
                ContextChipsView(
                    sessionContext: sessionContext, conversation: conversation,
                    cancelPending: cancelAttachmentImport
                )
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
        .composerBlock(
            style: surfaceStyle,
            isEmphasized: isFocused || isDropTargeted
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Metrics.Radius.large)
                    .stroke(.tint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.image.identifier],
            isTargeted: $isDropTargeted,
            perform: receiveDroppedContext
        )
        // Anchored to the whole surface rather than the TextEditor. The editor
        // begins inside the surface padding (and can have Context chips above
        // it), which let the palette overlap the Chat frame.
        .overlay(alignment: .top) { slashMenu }
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
        .alert(
            "Attachment Error",
            isPresented: Binding(
                get: { conversation.attachmentImportError != nil },
                set: { if !$0 { conversation.attachmentImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversation.attachmentImportError ?? "")
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
        TextEditor(text: draft)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .overlay(alignment: .topLeading) {
                if draft.wrappedValue.isEmpty, !hasMarkedText {
                    Text(prompt)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.editorTextInset)
                        .allowsHitTesting(false)
                }
            }
            .background {
                Text(draft.wrappedValue.isEmpty ? " " : draft.wrappedValue)
                    .font(.body)
                    .padding(.leading, Self.editorTextInset)
                    .padding(.vertical, Metrics.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        draftHeight = $0
                    }
            }
            .background {
                TextViewMarkedTextObserver(
                    hasMarkedText: $hasMarkedText,
                    paste: { isFocused && handleContextPaste() }
                )
            }
            .onPasteCommand(of: [.fileURL, .image, .text]) { _ in
                if !handleContextPaste() { insertShortPasteIntoEditor() }
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
                let editorHasMarkedText =
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
                guard !hasMarkedText, !editorHasMarkedText,
                    !press.modifiers.contains(.shift)
                else { return .ignored }
                let disallowed: EventModifiers = [.control, .option]
                guard press.modifiers.intersection(disallowed).isEmpty else { return .ignored }
                if acceptHighlightedSlashRow() { return .handled }
                sendDraft()
                return .handled
            }
            // Typing again after Escape re-opens the palette; the dismissal
            // was about one keystroke, not about the rest of the draft.
            .onChange(of: conversation.draft) { _, draft in
                isSlashMenuDismissed = false
                selectPreferredSlashOption(for: draft)
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
            .frame(
                height: min(
                    max(draftHeight, minimumDraftHeight),
                    maximumDraftHeight
                )
            )
            .zIndex(100)
    }

    private var minimumDraftHeight: CGFloat {
        maxContentWidth == nil
            ? Metrics.Chat.compactComposerMinHeight
            : Metrics.Chat.composerMinHeight
    }

    private var maximumDraftHeight: CGFloat {
        maxContentWidth == nil
            ? Metrics.Chat.compactComposerMaxHeight
            : Metrics.Chat.composerMaxHeight
    }

    /// `TextEditor`'s own leading text-container inset, which the placeholder
    /// and the measuring twin both have to match or the text jumps sideways
    /// when the field gains content.
    private static let editorTextInset: CGFloat = 5

    /// Stop and Send share one slot rather than standing side by side.
    ///
    /// Drawn together they read as a pair of equals, and the primary action
    /// moved under the pointer the moment the draft gained a character. With a
    /// draft to send, Send is what the button is for; with nothing to send,
    /// stopping is the only thing left to do.
    private var showsStopButton: Bool { conversation.isStreaming && !conversation.canSendDraft }

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
                    enabled: conversation.canSendDraft && conversation.pendingAttachments.isEmpty,
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
        if !conversation.pendingAttachments.isEmpty { return }
        if conversation.attachments.contains(where: { $0.image != nil }),
            resolved?.model.isVision != true
        {
            conversation.attachmentImportError = String(
                localized: "The selected model cannot read images. Choose a vision-capable model before sending."
            )
            return
        }
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
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Slash commands

    /// What this conversation offers. `/reasoning` only where the resolved model
    /// has more than one effort to choose between — a command that can only
    /// confirm what is already true is a row that wastes the reader's time.
    private var slashCommands: [ChatSlashCommand] {
        var commands: [ChatSlashCommand] = []
        if !conversation.isEmpty, onNewChat != nil {
            commands.append(
                ChatSlashCommand(
                    id: "new", displayName: String(localized: "New chat"),
                    summary: String(localized: "Start a new conversation"),
                    icon: .symbol("plus.bubble")
                ))
        }
        commands.append(
            ChatSlashCommand(
                id: "plan", displayName: String(localized: "Plan mode"),
                summary: conversation.isPlanning
                    ? String(localized: "Stop planning and act")
                    : String(localized: "Research and propose before acting"),
                icon: .symbol(PlanModeChip.symbol),
                // Free text, so `/plan why is root at 99%` both enters the mode
                // and asks the question. Typing `/plan` alone toggles it.
                argumentHint: String(localized: "what to plan")
            ))
        // Existing conversations always expose Compact, even before enough
        // history has accumulated to compact. A blank New chat has nothing it
        // could summarize, so the command would only be noise there.
        if !conversation.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "compact", displayName: String(localized: "Compact"),
                    summary: String(localized: "Summarize older turns to free context"),
                    icon: .contextRing,
                    argumentHint: String(localized: "what to emphasize")
                ))
        }
        if supportsThinking {
            commands.append(
                ChatSlashCommand(
                    id: "reasoning", displayName: String(localized: "Reasoning"),
                    summary: String(localized: "How hard the model thinks"),
                    icon: .symbol("brain"),
                    argumentHint: String(localized: "effort")
                ))
        }
        if !slashModelChoices.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "model", displayName: String(localized: "Model"),
                    summary: String(localized: "Switch the model for this conversation"),
                    icon: .symbol("sparkles"),
                    argumentHint: String(localized: "model")
                ))
        }
        if !app.aiConfiguration.mcpServers.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "mcp", displayName: String(localized: "MCP"),
                    summary: String(localized: "Enable or disable MCP servers"),
                    icon: .symbol("server.rack"),
                    argumentHint: String(localized: "server")
                ))
        }
        // Only the first page is alphabetical. A command's second page keeps
        // its semantic order — especially Reasoning's effort scale and the
        // configured order of providers and MCP servers.
        return commands.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private var slashOptions: (ChatSlashCommand) -> [ChatSlashCommand.Option] {
        { command in
            switch command.id {
            case "reasoning":
                guard let reasoningResolution else { return [] }
                return reasoningResolution.supported.map { effort in
                    ChatSlashCommand.Option(id: effort.rawValue, label: effort.displayName)
                }
            case "model":
                return slashModelChoices.map { choice in
                    ChatSlashCommand.Option(id: choice.argument, label: choice.model.label)
                }
            case "mcp":
                return app.aiConfiguration.mcpServers.map { server in
                    ChatSlashCommand.Option(
                        id: server.id.uuidString.lowercased(), label: server.name
                    )
                }
            default:
                return []
            }
        }
    }

    private var slashModelChoices: [(
        argument: String, provider: ModelProvider, model: AIModel
    )] {
        modelProviders.flatMap { provider in
            provider.assistantModels.map { model in
                (
                    argument: "\(provider.id.uuidString.lowercased()):\(model.id)",
                    provider: provider,
                    model: model
                )
            }
        }
    }

    private func slashModelChoice(
        for argument: String
    ) -> (argument: String, provider: ModelProvider, model: AIModel)? {
        slashModelChoices.first { $0.argument == argument }
    }

    private var slashCompletion: ChatSlashCommandCompletion {
        guard !isSlashMenuDismissed else { return ChatSlashCommandCompletion(rows: []) }
        return slashCompletion(for: conversation.draft)
    }

    private func slashCompletion(for draft: String) -> ChatSlashCommandCompletion {
        ChatSlashCommandCompletion.rows(
            draft: draft, commands: slashCommands, options: slashOptions
        )
    }

    /// Opening a single-choice page starts on the value this conversation
    /// already uses. Other pages, including MCP's independent toggles, start at
    /// the first row as before.
    private func preferredSlashSelection(
        in completion: ChatSlashCommandCompletion
    ) -> Int {
        guard case .option(let command, _) = completion.rows.first else { return 0 }

        switch command.id {
        case "reasoning":
            return completion.selectionIndex(
                commandID: command.id, optionID: effectiveReasoningEffort.rawValue
            )
        case "model":
            guard let resolved else { return 0 }
            let optionID =
                "\(resolved.provider.id.uuidString.lowercased()):\(resolved.model.id)"
            return completion.selectionIndex(commandID: command.id, optionID: optionID)
        default:
            return 0
        }
    }

    private func selectPreferredSlashOption(for draft: String) {
        let completion = slashCompletion(for: draft)
        slashSelection = preferredSlashSelection(in: completion)
        guard !completion.isEmpty else { return }
        // Completion changes also ask the menu to scroll, but this explicit
        // request runs after the preferred index has been installed.
        slashScrollRequest += 1
    }

    @ViewBuilder
    private var slashMenu: some View {
        let completion = slashCompletion
        if !completion.isEmpty {
            SlashCommandMenuView(
                completion: completion,
                selection: min(slashSelection, completion.rows.count - 1),
                scrollRequest: slashScrollRequest,
                surfaceStyle: surfaceStyle,
                contextShare: contextShare,
                trailingText: slashTrailingText,
                onHover: { slashSelection = $0 },
                onSelect: acceptSlashRow
            )
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
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
        case .command(let command) where command.id == "model":
            return resolvedModelLabel
        case .option(let command, let option) where command.id == "model":
            return slashModelChoice(for: option.id)?.provider.name
        case .option(let command, let option) where command.id == "mcp":
            guard
                let id = UUID(uuidString: option.id),
                let server = app.aiConfiguration.mcpServer(id)
            else { return nil }
            return server.isEnabled
                ? String(localized: "Enabled") : String(localized: "Disabled")
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
            let acceptedDraft = ChatSlashCommandCompletion.accepted(
                row, takesArgument: hasOptions
            )
            conversation.draft = acceptedDraft
            if hasOptions {
                // Install the correct index in the same action that opens the
                // second page, avoiding a frame highlighted on its first row.
                slashSelection = preferredSlashSelection(
                    in: slashCompletion(for: acceptedDraft)
                )
            } else {
                slashSelection = 0
            }
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
        case "new":
            guard !conversation.isEmpty, let onNewChat else { return false }
            clearSlashDraft()
            onNewChat()
            return true
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
        case "model":
            guard case .argument(_, let argument) = input,
                let choice = slashModelChoice(for: argument)
            else { return false }
            select(choice.model, on: choice.provider)
        case "mcp":
            guard case .argument(_, let argument) = input,
                let id = UUID(uuidString: argument),
                let server = app.aiConfiguration.mcpServer(id)
            else { return false }
            app.aiConfiguration.setServerEnabled(!server.isEnabled, for: id)
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
        slashScrollRequest += 1
        return true
    }

    private func composerMenus(compact: Bool) -> some View {
        HStack(spacing: Metrics.Space.s) {
            addContextButton
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

    private var addContextButton: some View {
        Button(action: chooseContextFiles) {
            Image(systemName: "plus")
                .font(.callout.weight(.medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .help(Text("Add context"))
        .accessibilityLabel(Text("Add context"))
    }

    private func chooseContextFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ContextAttachmentImporter.supportedContentTypes
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls.prefix(ContextAttachmentImporter.maximumAttachments) {
            guard let pending = conversation.beginAttachmentImport(label: url.lastPathComponent)
            else { break }
            let task = Task {
                do {
                    let chip = try await ContextAttachmentImporter.importFile(at: url)
                    conversation.finishAttachmentImport(pending.id, with: chip)
                } catch is CancellationError {
                    conversation.cancelAttachmentImport(pending.id)
                } catch {
                    conversation.failAttachmentImport(
                        pending.id,
                        message: "\(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                attachmentTasks[pending.id] = nil
            }
            attachmentTasks[pending.id] = task
        }
    }

    private func importImages(_ images: [Data]) {
        for data in images.prefix(ContextAttachmentImporter.maximumAttachments) {
            guard let pending = conversation.beginAttachmentImport(
                label: String(localized: "Dropped image")
            ) else { break }
            let task = Task {
                do {
                    let chip = try await ContextAttachmentImporter.importImage(
                        data: data, label: String(localized: "Dropped image")
                    )
                    conversation.finishAttachmentImport(pending.id, with: chip)
                } catch {
                    conversation.failAttachmentImport(
                        pending.id, message: error.localizedDescription
                    )
                }
                attachmentTasks[pending.id] = nil
            }
            attachmentTasks[pending.id] = task
        }
    }

    private func receiveDroppedContext(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers.prefix(ContextAttachmentImporter.maximumAttachments) {
            // An image dragged from Finder advertises both file-url and image.
            // Prefer the URL so its real filename survives into the Context Chip.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) { data, _ in
                    guard let data,
                        let url = URL(dataRepresentation: data, relativeTo: nil),
                        url.isFileURL
                    else { return }
                    Task { @MainActor in importFiles([url]) }
                }
                continue
            }

            guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { continue }
            accepted = true
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in importImages([data]) }
            }
        }
        return accepted
    }

    private func handleContextPaste() -> Bool {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !urls.isEmpty {
            importFiles(urls)
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard let pending = conversation.beginAttachmentImport(
                label: String(localized: "Pasted image")
            ) else { return true }
            let task = Task {
                do {
                    let chip = try await ContextAttachmentImporter.importImage(data: data)
                    conversation.finishAttachmentImport(pending.id, with: chip)
                } catch {
                    conversation.failAttachmentImport(
                        pending.id, message: error.localizedDescription
                    )
                }
                attachmentTasks[pending.id] = nil
            }
            attachmentTasks[pending.id] = task
            return true
        }
        guard let text = pasteboard.string(forType: .string),
            ContextAttachmentImporter.shouldAttachPastedText(text)
        else { return false }
        do { conversation.attach(try ContextAttachmentImporter.pastedText(text)) }
        catch { conversation.attachmentImportError = error.localizedDescription }
        return true
    }

    private func insertShortPasteIntoEditor() {
        guard isFocused, let text = NSPasteboard.general.string(forType: .string),
            let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func cancelAttachmentImport(_ id: PendingContextAttachment.ID) {
        attachmentTasks[id]?.cancel()
        attachmentTasks[id] = nil
        conversation.cancelAttachmentImport(id)
    }

    private func permissionMenu(compact: Bool) -> some View {
        Button {
            isModelPickerPresented = false
            isPermissionPickerPresented.toggle()
        } label: {
            if compact {
                Image(systemName: resolvedPermissionMode.symbol)
                    .font(.body)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(permissionTint)
                    .frame(width: 24, height: 24)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    Image(systemName: resolvedPermissionMode.symbol)
                        .symbolRenderingMode(.monochrome)
                    Text(resolvedPermissionMode.displayName)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(permissionTint)
                .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPermissionPickerPresented, arrowEdge: .bottom) {
            permissionPopover
        }
        .help(Text("Permission: \(resolvedPermissionMode.displayName)"))
        .accessibilityLabel(Text("Permission, \(resolvedPermissionMode.displayName)"))
    }

    private var permissionPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permission")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.top, Metrics.Space.l)
                .padding(.bottom, Metrics.Space.s)

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                ForEach(ChatPermissionMode.allCases) { mode in
                    Button {
                        conversation.permissionMode = mode
                        app.aiConfiguration.select(mode)
                    } label: {
                        permissionOptionRow(mode)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.Space.s)
            .padding(.bottom, Metrics.Space.s)
        }
        .frame(width: 320)
        // The same system glass the composer that raised it is made of, rather
        // than a flat panel colour — a popover anchored to a glass surface that
        // is itself opaque reads as a different app's window. The presentation
        // background is cleared so the glass is the background rather than a
        // sheen painted over the popover's own opaque chrome.
        .termindGlassSurface(cornerRadius: Metrics.Radius.large)
        .presentationBackground(.clear)
    }

    private func permissionOptionRow(_ mode: ChatPermissionMode) -> some View {
        let isSelected = mode == resolvedPermissionMode
        let isFullAccess = mode == .fullAccess
        return HStack(alignment: .center, spacing: Metrics.Space.m) {
            Image(systemName: mode.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFullAccess ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20, alignment: .center)

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                Text(mode.displayName)
                    .foregroundStyle(isFullAccess ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Text(permissionDescription(mode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Metrics.Space.s)

            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
        }
        .font(.callout)
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: Metrics.Radius.medium)
        )
        .contentShape(.rect)
    }

    private func permissionDescription(_ mode: ChatPermissionMode) -> LocalizedStringKey {
        switch mode {
        case .askForApproval: "Ask before protected actions"
        case .approveForMe: "Use Security Review automatically"
        case .fullAccess: "Run protected actions without review"
        }
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
        Button {
            isPermissionPickerPresented = false
            isModelPickerPresented.toggle()
        } label: {
            if compact {
                modelGlyph(compact: true)
                    .frame(width: 24, height: 24)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    Label {
                        Text(modelAndThinkingLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        modelGlyph(compact: false)
                            .font(.caption2)
                    }
                    .labelStyle(.titleAndIcon)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
            modelAndThinkingPopover
        }
        .onChange(of: isModelPickerPresented) { _, isPresented in
            if !isPresented { expandedModelPickerSection = nil }
        }
        .help(Text(modelAndThinkingHelp))
        .accessibilityLabel(Text(modelAndThinkingAccessibilityLabel))
    }

    private var modelAndThinkingPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if contextEstimate.total > 0 {
                ContextBreakdownView(
                    estimate: contextEstimate,
                    contextWindow: resolved?.model.contextLength,
                    cachedInputTokens: conversation.usage?.cachedInputTokens ?? 0
                )
                .padding(Metrics.Space.l)

                Divider()
            }

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                Button {
                    toggleModelPickerSection(.model)
                } label: {
                    modelPickerRow(
                        title: String(localized: "Model"),
                        value: resolvedModelLabel,
                        isExpanded: expandedModelPickerSection == .model
                    )
                }
                .buttonStyle(.plain)

                if expandedModelPickerSection == .model {
                    modelOptions
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if supportsThinking, let reasoningResolution {
                    Button {
                        toggleModelPickerSection(.thinking)
                    } label: {
                        modelPickerRow(
                            title: String(localized: "Effort"),
                            value: effectiveReasoningEffort.displayName,
                            isExpanded: expandedModelPickerSection == .thinking
                        )
                    }
                    .buttonStyle(.plain)

                    if expandedModelPickerSection == .thinking {
                        thinkingOptions(reasoningResolution)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(Metrics.Space.s)
            .animation(
                Motion.panel(reduceMotion: reduceMotion),
                value: expandedModelPickerSection
            )

            Divider()

            Button {
                isModelPickerPresented = false
                openSettings()
            } label: {
                Label("Configure Model Providers", systemImage: "slider.horizontal.3")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.Space.l)
                    .padding(.vertical, Metrics.Space.m)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 264)
        .termindGlassSurface(cornerRadius: Metrics.Radius.large)
        .presentationBackground(.clear)
    }

    private func modelPickerRow(
        title: String, value: String, isExpanded: Bool
    ) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Text(title)
            Spacer(minLength: Metrics.Space.l)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .font(.callout)
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, Metrics.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var modelOptions: some View {
        AssistantModelOptionNativeList(items: modelOptionItems) { item in
            switch item.content {
            case .empty:
                Text("No models configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.Space.m)
            case .provider(_, let name):
                Text(name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Metrics.Space.m)
            case .model(let provider, let model, let selected):
                Button {
                    select(model, on: provider)
                } label: {
                    pickerOptionRow(model.label, isSelected: selected)
                }
                .buttonStyle(.plain)
            }
        }
        // A max height alone has no intrinsic answer inside a newly presented
        // popover. On its first expansion AppKit proposed zero, so Model looked
        // inert until the shorter Effort section forced a second layout pass.
        // A deterministic natural height makes the first click work and still
        // caps large provider lists behind scrolling.
        .frame(height: modelOptionsHeight)
        .padding(.bottom, Metrics.Space.xs)
    }

    private var modelOptionItems: [AssistantModelOptionListItem] {
        guard !modelProviders.isEmpty else { return [.empty] }
        return modelProviders.flatMap { provider in
            [.provider(provider)] + provider.assistantModels.map { model in
                .model(provider: provider, model: model, selected: isSelected(model, on: provider))
            }
        }
    }

    private var modelOptionsHeight: CGFloat {
        min(220, max(34, modelOptionItems.reduce(0) { $0 + $1.height }))
    }

    private func thinkingOptions(
        _ resolution: ModelCapabilityResolver.ReasoningResolution
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
            ForEach(resolution.supported) { effort in
                Button {
                    conversation.reasoningEffort = effort
                } label: {
                    pickerOptionRow(
                        effort.displayName,
                        isSelected: effort == effectiveReasoningEffort
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, Metrics.Space.xs)
    }

    private func pickerOptionRow(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: Metrics.Sidebar.rowIcon)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: Metrics.Radius.medium)
        )
        .contentShape(.rect)
    }

    private func toggleModelPickerSection(_ section: ModelPickerSection) {
        expandedModelPickerSection = expandedModelPickerSection == section ? nil : section
    }

    /// The same ring is retained at zero before there is something to weigh.
    ///
    /// Replacing the glyph rather than adding a second one: the row is already
    /// four controls wide at 260pt, and a conversation's size is a property of
    /// the model it is being sent to, which is what this menu is about.
    @ViewBuilder
    private func modelGlyph(compact: Bool) -> some View {
        // This is a SwiftUI popover button, not an AppKit `NSMenu` label. Use
        // the same live shape as `/compact` so its transparent centre and
        // semantic track resolve against the current light/dark appearance.
        ContextRing(share: contextShare ?? 0)
            // One column for both. The ring arrives the moment the first turn
            // reports its usage, and a glyph that changed width at that moment
            // would shift the model name sideways mid-reply.
            .frame(width: compact ? 24 : PlanModeChip.glyphWidth)
    }

    private var modelAndThinkingLabel: String {
        guard resolved != nil, supportsThinking else { return resolvedModelLabel }
        return "\(resolvedModelLabel) · \(effectiveReasoningEffort.displayName)"
    }

    private var modelAndThinkingAccessibilityLabel: String {
        guard resolved != nil else { return String(localized: "Model, no model configured") }
        guard supportsThinking else { return String(localized: "Model \(resolvedModelLabel)") }
        return String(
            localized: "Model \(resolvedModelLabel), effort \(effectiveReasoningEffort.displayName)"
        )
    }

    private var modelAndThinkingHelp: String {
        if let resolved {
            guard supportsThinking else {
                return String(localized: "\(resolved.model.label) through \(resolved.provider.name)")
            }
            return String(
                localized:
                    "\(resolved.model.label) through \(resolved.provider.name) · \(effectiveReasoningEffort.displayName) effort"
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

}

nonisolated private struct AssistantModelOptionListItem: Identifiable, Hashable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        case empty
        case provider(ModelProvider.ID)
        case model(ModelProvider.ID, AIModel.ID)
    }

    nonisolated enum Content: Hashable, Sendable {
        case empty
        case provider(ModelProvider.ID, name: String)
        case model(ModelProvider, AIModel, selected: Bool)
    }

    let id: ID
    let content: Content

    static let empty = Self(id: .empty, content: .empty)

    static func provider(_ provider: ModelProvider) -> Self {
        .init(id: .provider(provider.id), content: .provider(provider.id, name: provider.name))
    }

    static func model(provider: ModelProvider, model: AIModel, selected: Bool) -> Self {
        .init(
            id: .model(provider.id, model.id),
            content: .model(provider, model, selected: selected)
        )
    }

    var height: CGFloat {
        switch content {
        case .empty: 34
        case .provider: 18
        case .model: 25
        }
    }
}

private struct AssistantModelOptionNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<AssistantModelOptionListItem>
    typealias Renderer = @MainActor (AssistantModelOptionListItem) -> AnyView

    let items: [AssistantModelOptionListItem]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [AssistantModelOptionListItem],
        @ViewBuilder renderer: @escaping @MainActor (AssistantModelOptionListItem) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [AssistantModelOptionListItem] = []

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 25
            listView.rows {
                ListRow(AssistantModelOptionHostingRow.self)
                    .height { item, _ in item.height }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [AssistantModelOptionListItem],
            renderer: @escaping Renderer, locale: Locale, colorScheme: ColorScheme
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items, animated: !content.isEmpty)
            }
            content = items
        }

        private func configure(
            _ row: AssistantModelOptionHostingRow,
            item: AssistantModelOptionListItem
        ) {
            guard let renderer else { return }
            let root = renderer(item)
                .id(item.id)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(root))
        }
    }
}

@MainActor
private final class AssistantModelOptionHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView.rootView = AnyView(EmptyView())
    }
    func configure(rootView: AnyView) { hostingView.rootView = rootView }
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
