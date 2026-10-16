import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
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

/// Makes AppKit hide the TextEditor's vertical scroller while its document fits.
///
/// SwiftUI's scroll-indicator visibility does not remove the disabled scroller
/// from a macOS TextEditor when the system is configured to always show scroll
/// bars. The underlying NSScrollView already knows whether its document exceeds
/// the clip view, so leave that decision to `autohidesScrollers` instead of
/// duplicating it from the composer's approximate text-height measurement.
struct TextEditorScrollViewConfigurator: NSViewRepresentable {
    final class ResolverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureAfterLayout()
        }

        override func layout() {
            super.layout()
            configureScrollView()
        }

        func configureAfterLayout() {
            Task { @MainActor [weak self] in self?.configureScrollView() }
        }

        private func configureScrollView() {
            guard let contentView = window?.contentView, !bounds.isEmpty,
                let scrollView = textEditorScrollView(in: contentView)
            else { return }

            guard !scrollView.autohidesScrollers || !scrollView.hasVerticalScroller else { return }
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.tile()
        }

        private func textEditorScrollView(in root: NSView) -> NSScrollView? {
            let targetFrame = convert(bounds, to: root)
            let targetCenter = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
            return descendantScrollViews(in: root).first { scrollView in
                guard let textView = scrollView.documentView as? NSTextView, textView.isEditable else {
                    return false
                }
                return scrollView.convert(scrollView.bounds, to: root).contains(targetCenter)
            }
        }

        private func descendantScrollViews(in root: NSView) -> [NSScrollView] {
            var result: [NSScrollView] = []
            func visit(_ view: NSView) {
                if let scrollView = view as? NSScrollView { result.append(scrollView) }
                view.subviews.forEach(visit)
            }
            visit(root)
            return result
        }
    }

    func makeNSView(context: Context) -> ResolverView {
        ResolverView(frame: .zero)
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.configureAfterLayout()
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
/// can be taken back off. So a composer with no session — the Assistant destination,
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
            ForEach(conversation.composer.attachments) { chip in
                ChipView(chip: chip) { conversation.detach(chip.id) }
            }
            ForEach(conversation.composer.pendingAttachments) { pending in
                PendingChipView(pending: pending) {
                    cancelPending(pending.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Assistant.attachedContext))
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
                    .accessibilityLabel(Text(AppStrings.Common.removeNamed(chip.label)))
            } else {
                styledContent(removable: false)
            }
        }
        .help(
            Text(
                remove == nil
                    ? String(localized: AppStrings.Assistant.alwaysIncluded)
                    : String(localized: AppStrings.Assistant.removeAttachment)
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
        .help(Text(AppStrings.Assistant.cancelImport))
        .accessibilityLabel(Text(AppStrings.Assistant.cancelImporting(pending.label)))
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
        let usedWidth =
            rows.map { row in
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
/// The one interactive surface in the Assistant column.
///
/// Composer, Steering and the archived-conversation notice are the same object
/// seen three times, so they share a radius, a material and a tint rather than
/// each drawing its own. Steering used to paint an opaque `.bar` with a
/// hand-drawn stroke directly above a Composer made of system glass, which read
/// as two unrelated panels stacked by accident.
private struct AssistantInteractionSurface: ViewModifier {
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content
            .padding(Metrics.Space.l)
            // Untinted. The sidebar copy used to carry a grey wash to separate
            // it from the column behind, which is a job system glass already
            // does — and the wash was enough to make the composer read as a
            // flat box with a sheen rather than as glass.
            .background {
                AssistantInteractionGlass(isEmphasized: isEmphasized)
                    .equatable()
            }
    }
}

private struct AssistantInteractionGlass: View, Equatable {
    let isEmphasized: Bool

    var body: some View {
        Color.clear
            .termindGlassSurface(
                cornerRadius: Metrics.Chat.composerRadius,
                isInteractive: isEmphasized
            )
            .allowsHitTesting(false)
    }
}

extension View {
    func assistantInteractionSurface(
        isEmphasized: Bool = false
    ) -> some View {
        modifier(
            AssistantInteractionSurface(
                isEmphasized: isEmphasized
            )
        )
    }

    /// The composer's own name for the shared surface, kept so the call sites
    /// that mean "this is the composer block" still read that way.
    func composerBlock(
        isEmphasized: Bool = false
    ) -> some View {
        assistantInteractionSurface(isEmphasized: isEmphasized)
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
                    Text(AppStrings.Assistant.plan)
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
        .help(Text(AppStrings.Assistant.planModeClickToTurnOff))
        .accessibilityLabel(Text(AppStrings.Assistant.planModeOnTurnOff))
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

/// The skill `/skill` named for the message being written.
///
/// It carries the skill's name rather than a generic word, because which one is
/// the entire content of the decision — and it is dismissed the same way plan
/// mode is, by clicking the chip. Unlike that one it survives a single message:
/// the next turn is composed without it, since a loaded skill is already in the
/// transcript by then and saying so twice would only spend context.
private struct SkillChip: View {
    let name: String
    let compact: Bool
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: Metrics.Space.xs) {
                Image(systemName: isHovering ? "xmark" : Self.symbol)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: PlanModeChip.glyphWidth)
                if !compact {
                    Text(name).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(AppStrings.Assistant.armedSkillHelp(name)))
        .accessibilityLabel(Text(AppStrings.Assistant.skillArmedRemove(name)))
    }

    /// A closed book: a procedure that exists and has not been opened yet, which
    /// is exactly the state a named-but-unloaded skill is in. The same glyph
    /// carries it through the `/skill` row and the `skill_read_file` card.
    static let symbol = "book.closed"
}

struct ComposerView: View {
    @Environment(\.locale) private var locale
    private enum ModelPickerSection {
        case model
        case thinking
    }

    let conversation: ConversationModel
    var prompt: LocalizedStringResource = AppStrings.Assistant.prompt
    /// The full Assistant destination shares one centered column with its transcript.
    /// `nil` keeps compact/sidebar composers fluid.
    var maxContentWidth: CGFloat? = nil
    /// What the surface showing this composer knows about the focused pane.
    /// Defaulting to `.none` is what makes a composer outside a Workspace — the
    /// Assistant destination — session-free by construction rather than by remembering.
    var sessionContext: SessionContext = .none
    /// The registry stays stable across surfaces; the Workspace sidebar permits
    /// command-card execution while standalone Assistant surfaces do not.
    var terminalSuggestionsAvailable = false
    var onNewChat: (() -> Void)?
    var onSend: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var transcriptionOwnerID = UUID()
    @State private var draftBeforeTranscription = ""
    @State private var slashSelection = 0
    @State private var slashScrollRequest = 0
    @State private var slashMenuHeight: CGFloat = 0
    private let slashRegistry = ChatSlashCommandRegistry.standard()
    /// Escape closes the palette without clearing the draft, so the draft alone
    /// cannot decide whether it is open.
    @State private var isSlashMenuDismissed = false
    @State private var draftHeight = Metrics.Chat.compactComposerMinHeight
    @State private var hasMarkedText = false
    @State private var isPermissionPickerPresented = false
    @State private var isModelPickerPresented = false
    @State private var expandedModelPickerSection: ModelPickerSection?

    private var resolved: (provider: ModelProvider, model: AIModel)? {
        app.aiConfiguration.resolve(conversation: conversation.model)
    }

    private var modelProviders: [ModelProvider] {
        app.aiConfiguration.enabledModelProviders.filter { !$0.assistantModels.isEmpty }
    }

    private var resolvedModelLabel: String {
        resolved?.model.label ?? String(localized: AppStrings.Assistant.noModel)
    }

    private var resolvedPermissionMode: AgentPermissionMode {
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
        transcription.isOwned(by: transcriptionOwnerID)
    }

    private var showsTranscriptionControls: Bool {
        ownsTranscription && transcription.phase != .idle
    }

    var body: some View {
        @Bindable var composer = conversation.composer
        let estimate = conversation.contextEstimate
        let share = contextShare(for: estimate)

        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !sessionContext.isEmpty || !composer.attachments.isEmpty
                || !composer.pendingAttachments.isEmpty
            {
                ContextChipsView(
                    sessionContext: sessionContext, conversation: conversation,
                    cancelPending: cancelAttachmentImport
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            draftEditor($composer.draft)

            ZStack {
                if showsTranscriptionControls {
                    transcriptionControls
                        .transition(.opacity)
                } else {
                    standardControls(contextEstimate: estimate)
                        .transition(.opacity)
                }
            }
            // Both modes occupy the same bottom toolbar slot. Recording must
            // never replace or vertically relocate the draft editor.
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .animation(Motion.panel(reduceMotion: reduceMotion), value: showsTranscriptionControls)
        }
        .composerBlock(isEmphasized: isFocused)
        // Anchored to the whole surface rather than the TextEditor. The editor
        // begins inside the surface padding (and can have Context chips above
        // it), which let the palette overlap the Chat frame.
        .overlay(alignment: .top) { slashMenu(contextShare: share) }
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
            guard transcription.isOwned(by: transcriptionOwnerID) else { return }
            conversation.composer.draft = draftBeforeTranscription
            transcription.cancel(ownerID: transcriptionOwnerID)
        }
        .alert(
            transcriptionError?.title ?? String(localized: AppStrings.Assistant.transcriptionFailed),
            isPresented: transcriptionErrorPresented
        ) {
            if transcriptionError?.offersSystemSettings == true {
                Button(AppStrings.Assistant.openSystemSettings.swiftUIKey) { openTranscriptionPrivacySettings() }
            }
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {}
        } message: {
            if let error = transcriptionError {
                Text(error.message)
            }
        }
        .alert(
            AppStrings.Assistant.attachmentError,
            isPresented: Binding(
                get: { conversation.composer.attachmentImportError != nil },
                set: { if !$0 { conversation.composer.attachmentImportError = nil } }
            )
        ) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {}
        } message: {
            Text(conversation.composer.attachmentImportError ?? "")
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
            .background { TextEditorScrollViewConfigurator() }
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
            .onChange(of: conversation.composer.draft) { _, draft in
                isSlashMenuDismissed = false
                selectPreferredSlashOption(for: draft)
            }
            // The Stop button gives its slot to Send as soon as the draft
            // has a character in it — which is exactly when this field has
            // focus. Without this, typing would make a run unstoppable
            // until the draft was cleared again.
            .onKeyPress(KeyEquivalent("."), phases: .down) { press in
                guard conversation.isAgentRunActive, press.modifiers.contains(.command) else {
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
    private var showsStopButton: Bool {
        conversation.isPreparingAgentRun || (conversation.isStreaming && !conversation.canSendDraft)
    }

    private func standardControls(contextEstimate: AgentContextEstimate) -> some View {
        HStack(spacing: Metrics.Space.s) {
            ViewThatFits(in: .horizontal) {
                composerMenus(compact: false, contextEstimate: contextEstimate)
                composerMenus(compact: true, contextEstimate: contextEstimate)
            }
            .frame(maxWidth: .infinity)

            transcribeButton
            if showsStopButton {
                stopButton
            } else {
                sendButton(
                    enabled: conversation.canSendDraft && conversation.composer.pendingAttachments.isEmpty,
                    help: conversation.isStreaming
                        ? AppStrings.Assistant.queueForTheRunningAgent : AppStrings.Assistant.sendLabel,
                    action: sendDraft
                )
            }
        }
        .animation(Motion.panel(reduceMotion: reduceMotion), value: showsStopButton)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
    }

    private var stopButton: some View {
        Button(action: conversation.stop) {
            Label(AppStrings.Common.stop.swiftUIKey, systemImage: "stop.circle.fill")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .termindShortcut(".")
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.red)
        .frame(width: 32, height: 32)
        .contentShape(.circle)
        .help(Text(AppStrings.Assistant.stopCurrentRun))
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
            !transcription.canStart(for: transcriptionOwnerID)
                || (ownsTranscription && transcription.isRequestingAuthorization)
        )
        .help(Text(AppStrings.Assistant.transcribeWithAppleSpeech))
        .accessibilityLabel(Text(AppStrings.Assistant.transcribe))
    }

    @ViewBuilder
    private var transcriptionControls: some View {
        switch transcription.phase {
        case .recording:
            HStack(spacing: Metrics.Space.m) {
                circularControl(
                    title: AppStrings.Assistant.cancelTranscription,
                    systemImage: "xmark",
                    action: cancelTranscription
                )

                SpeechWaveformView(
                    samples: transcription.levelSamples,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: .infinity, minHeight: 32)
                .accessibilityLabel(Text(AppStrings.Assistant.recording))

                circularControl(
                    title: AppStrings.Assistant.stopRecording,
                    systemImage: "stop.fill",
                    action: { transcription.stop(ownerID: transcriptionOwnerID) }
                )

                sendButton(
                    enabled: true,
                    action: {
                        transcription.stop(
                            ownerID: transcriptionOwnerID,
                            sendAfterTranscription: true
                        )
                    }
                )
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        case .transcribing:
            HStack(spacing: Metrics.Space.m) {
                circularControl(
                    title: AppStrings.Assistant.cancelTranscription,
                    systemImage: "xmark",
                    action: cancelTranscription
                )

                Spacer(minLength: Metrics.Space.s)
                Text(AppStrings.Assistant.transcribing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: Metrics.Space.s)

                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.55), in: .circle)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(AppStrings.Assistant.transcribing))

                sendButton(enabled: false, action: {})
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        case .idle:
            EmptyView()
        }
    }

    private func sendButton(
        enabled: Bool,
        help: LocalizedStringResource = AppStrings.Assistant.sendLabel,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(AppStrings.Assistant.send.swiftUIKey, systemImage: "arrow.up.circle.fill")
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
        title: LocalizedStringResource,
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
        guard transcription.errorOwnerID == transcriptionOwnerID else { return nil }
        return transcription.error
    }

    private var transcriptionErrorPresented: Binding<Bool> {
        Binding(
            get: { transcriptionError != nil },
            set: { presented in
                if !presented { transcription.dismissError(ownerID: transcriptionOwnerID) }
            }
        )
    }

    private func beginTranscription() {
        draftBeforeTranscription = conversation.composer.draft
        Task {
            await transcription.start(ownerID: transcriptionOwnerID) { transcript, shouldSend in
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
        conversation.composer.draft = draftBeforeTranscription
        transcription.cancel(ownerID: transcriptionOwnerID)
        isFocused = true
    }

    private func sendDraft() {
        // First, and before the streaming check: a command is not a message, so
        // it is not queued at a busy agent either. `/reasoning high` mid-run
        // changes the next request, which is exactly when someone would type it.
        if runSlashCommand() { return }
        // Gate before consuming the draft, queueing steering text, creating a
        // conversation, or appending a visible user turn. The runtime keeps a
        // second guard, but by then the UI would already look as though Send
        // succeeded.

        if !conversation.composer.pendingAttachments.isEmpty { return }
        if conversation.composer.attachments.contains(where: { $0.image != nil }),
            resolved?.model.isVision != true
        {
            conversation.composer.attachmentImportError = String(
                localized: AppStrings.Assistant.visionModelRequirement
            )
            return
        }
        if conversation.isStreaming {
            conversation.submitSteeringDraft(
                context: sessionContext, terminalSuggestionsAvailable: terminalSuggestionsAvailable)
            return
        }
        if let onSend {
            onSend()
        } else {
            app.sendAgentDraft(
                conversation, context: sessionContext,
                terminalSuggestionsAvailable: terminalSuggestionsAvailable, window: window
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

    private var slashContext: ChatSlashCommandContext {
        ChatSlashCommandContext(
            platform: .desktop,
            conversation: conversation,
            configuration: app.aiConfiguration,
            skills: app.skills,
            archive: {
                window.setAssistantArchived(conversation.id, archived: true)
            },
            newConversation: onNewChat,
            compact: { instructions in
                Task { await app.compact(conversation, instructions: instructions) }
            },
            send: sendDraft,
            selectModel: { ref in
                do {
                    try app.assistantModelSelections.select(ref, for: conversation)
                    return true
                } catch {
                    window.assistantOperationError = error.localizedDescription
                    return false
                }
            }
        )
    }

    private var slashOptions: (ChatSlashCommand) -> [ChatSlashCommand.Option] {
        { slashRegistry.options(for: $0, in: slashContext) }
    }

    private var slashCompletion: ChatSlashCommandCompletion {
        guard !isSlashMenuDismissed else { return ChatSlashCommandCompletion(rows: []) }
        return slashCompletion(for: conversation.composer.draft)
    }

    private func slashCompletion(for draft: String) -> ChatSlashCommandCompletion {
        slashRegistry.completion(for: draft, in: slashContext)
    }

    /// Opening a single-choice page starts on the value this conversation
    /// already uses. Other pages, including MCP's independent toggles, start at
    /// the first row as before.
    private func preferredSlashSelection(
        in completion: ChatSlashCommandCompletion
    ) -> Int {
        slashRegistry.preferredSelection(in: completion, context: slashContext)
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
    private func slashMenu(contextShare: Double?) -> some View {
        let completion = slashCompletion
        if !completion.isEmpty {
            SlashCommandMenuView(
                completion: completion,
                selection: min(slashSelection, completion.rows.count - 1),
                scrollRequest: slashScrollRequest,
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
        slashRegistry.trailingText(for: row, in: slashContext)
    }

    /// Completing a name leaves the command in the field; running it consumes
    /// only the trailing slash fragment and preserves any prompt before it.
    private func acceptSlashRow(_ row: ChatSlashCommandCompletion.Row) {
        switch row {
        case .command(let command):
            // Advance to a second palette page only when there is one. Free text
            // — `/plan <question>`, `/compact <instructions>` — is typed, not
            // chosen, so a command that takes it still runs on Return and the
            // argument is for whoever wants to type one.
            let hasOptions = !slashOptions(command).isEmpty
            let acceptedDraft = ChatSlashCommandCompletion.accepted(
                row, takesArgument: hasOptions, in: conversation.composer.draft
            )
            conversation.composer.draft = acceptedDraft
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
            conversation.composer.draft = ChatSlashCommandCompletion.accepted(
                row, takesArgument: false, in: conversation.composer.draft
            )
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
        let performed = slashRegistry.perform(draft: conversation.composer.draft, in: slashContext)
        if performed {
            isSlashMenuDismissed = false
            slashSelection = 0
        }
        return performed
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

    private func composerMenus(
        compact: Bool, contextEstimate: AgentContextEstimate
    ) -> some View {
        HStack(spacing: Metrics.Space.s) {
            addContextButton
            permissionMenu(compact: compact)
            if conversation.isPlanning {
                PlanModeChip(compact: compact) { conversation.isPlanning = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if let armed = conversation.composer.armedSkillName {
                SkillChip(name: armed, compact: compact) {
                    conversation.composer.armedSkillName = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Spacer(minLength: Metrics.Space.s)
            modelAndThinkingMenu(compact: compact, contextEstimate: contextEstimate)
        }
        .animation(Motion.panel(reduceMotion: reduceMotion), value: conversation.isPlanning)
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: conversation.composer.armedSkillName
        )
    }

    private var addContextButton: some View {
        Button(action: chooseContextFiles) {
            Image(systemName: "plus")
                .font(.callout.weight(.medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .help(Text(AppStrings.Assistant.addContext))
        .accessibilityLabel(Text(AppStrings.Assistant.addContext))
    }

    private func chooseContextFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ContextAttachmentImporter.supportedContentTypes
        guard panel.runModal() == .OK else { return }
        conversation.attachmentLoader = .live
        conversation.importAttachmentFiles(panel.urls)
    }

    private func handleContextPaste() -> Bool {
        let pasteboard = NSPasteboard.general
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        if !urls.isEmpty {
            conversation.attachmentLoader = .live
            conversation.importAttachmentFiles(urls)
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            conversation.attachmentLoader = .live
            conversation.importAttachmentImages(
                [data], label: String(localized: AppStrings.Assistant.pastedImage)
            )
            return true
        }
        guard let text = pasteboard.string(forType: .string),
            ContextAttachmentImporter.shouldAttachPastedText(text)
        else { return false }
        do { conversation.attach(try ContextAttachmentImporter.pastedText(text)) } catch {
            conversation.composer.attachmentImportError = error.localizedDescription
        }
        return true
    }

    private func insertShortPasteIntoEditor() {
        guard isFocused, let text = NSPasteboard.general.string(forType: .string),
            let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func cancelAttachmentImport(_ id: PendingContextAttachment.ID) {
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
        .termindInputAwareFocusEffect()
        .fixedSize()
        .popover(isPresented: $isPermissionPickerPresented, arrowEdge: .bottom) {
            permissionPopover
        }
        .help(Text(AppStrings.Assistant.permissionNamed(resolvedPermissionMode.displayName)))
        .accessibilityLabel(Text(AppStrings.Assistant.permission(resolvedPermissionMode.displayName)))
    }

    private var permissionPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppStrings.Common.permission)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.top, Metrics.Space.l)
                .padding(.bottom, Metrics.Space.s)

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                ForEach(AgentPermissionMode.allCases) { mode in
                    Button {
                        conversation.permissionMode = mode
                        app.aiConfiguration.select(mode)
                    } label: {
                        permissionOptionRow(mode)
                    }
                    .buttonStyle(.plain)
                    .termindInputAwareFocusEffect()
                }
            }
            .padding(.horizontal, Metrics.Space.s)
            .padding(.bottom, Metrics.Space.s)
        }
        .frame(width: 360)
        // The same system glass the composer that raised it is made of, rather
        // than a flat panel colour — a popover anchored to a glass surface that
        // is itself opaque reads as a different app's window. The presentation
        // background is cleared so the glass is the background rather than a
        // sheen painted over the popover's own opaque chrome.
        .termindGlassSurface(cornerRadius: Metrics.Radius.large)
        .presentationBackground(.clear)
    }

    private func permissionOptionRow(_ mode: AgentPermissionMode) -> some View {
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

    private func permissionDescription(_ mode: AgentPermissionMode) -> LocalizedStringResource {
        switch mode {
        case .askForApproval: AppStrings.Assistant.alwaysAskForApprovalBeforeProtectedActions
        case .approveForMe: AppStrings.Assistant.onlyAskForActionsDetectedAsPotentiallyUnsafe
        case .fullAccess: AppStrings.Assistant.unrestrictedToTheInternetAndAnyFilesOnYourHosts
        }
    }

    private var permissionTint: Color {
        resolvedPermissionMode == .fullAccess ? .red : .secondary
    }

    private func contextShare(for estimate: AgentContextEstimate) -> Double? {
        // No window, no ring. A gateway that does not report `contextLength`
        // leaves us with a numerator and no denominator, and a ring drawn on a
        // guessed window would be a confident picture of nothing.
        guard estimate.total > 0 else { return nil }
        return estimate.share(of: resolved?.model.contextLength)
    }

    private func modelAndThinkingMenu(
        compact: Bool, contextEstimate: AgentContextEstimate
    ) -> some View {
        let share = contextShare(for: contextEstimate)
        return Button {
            isPermissionPickerPresented = false
            isModelPickerPresented.toggle()
        } label: {
            if compact {
                modelGlyph(compact: true, contextShare: share)
                    .frame(width: 24, height: 24)
                    .contentShape(.circle)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    Label {
                        Text(modelAndThinkingLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        modelGlyph(compact: false, contextShare: share)
                            .font(.caption2)
                    }
                    .labelStyle(.titleAndIcon)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .termindInputAwareFocusEffect()
        .foregroundStyle(.secondary)
        .fixedSize()
        .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
            modelAndThinkingPopover(contextEstimate: contextEstimate)
        }
        .onChange(of: isModelPickerPresented) { _, isPresented in
            if !isPresented { expandedModelPickerSection = nil }
        }
        .help(Text(modelAndThinkingHelp))
        .accessibilityLabel(Text(modelAndThinkingAccessibilityLabel))
    }

    private func modelAndThinkingPopover(
        contextEstimate: AgentContextEstimate
    ) -> some View {
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
                        title: String(localized: AppStrings.Assistant.model),
                        value: resolvedModelLabel,
                        isExpanded: expandedModelPickerSection == .model
                    )
                }
                .buttonStyle(.plain)
                .termindInputAwareFocusEffect()

                if expandedModelPickerSection == .model {
                    modelOptions
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if supportsThinking, let reasoningResolution {
                    Button {
                        toggleModelPickerSection(.thinking)
                    } label: {
                        modelPickerRow(
                            title: String(localized: AppStrings.Assistant.effort),
                            value: effectiveReasoningEffort.displayName,
                            isExpanded: expandedModelPickerSection == .thinking
                        )
                    }
                    .buttonStyle(.plain)
                    .termindInputAwareFocusEffect()

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
                window.openSettings(route: .category(.ai))
            } label: {
                Label(AppStrings.Assistant.configureModelProviders.swiftUIKey, systemImage: "slider.horizontal.3")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.Space.l)
                    .padding(.vertical, Metrics.Space.m)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .termindInputAwareFocusEffect()
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(modelOptionItems) { item in
                    Group {
                        switch item.content {
                        case .empty:
                            Text(AppStrings.Assistant.noModelsConfigured)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Metrics.Space.m)
                        case .provider(_, let name):
                            Text(name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Metrics.Space.m)
                        case .model(let provider, let model, let selected):
                            Button {
                                select(model, on: provider)
                            } label: {
                                pickerOptionRow(model.label, isSelected: selected)
                            }
                            .buttonStyle(.plain)
                            .termindInputAwareFocusEffect()
                        }
                    }
                    .frame(height: item.height)
                }
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
            [.provider(provider)]
                + provider.assistantModels.map { model in
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
                .termindInputAwareFocusEffect()
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
    private func modelGlyph(compact: Bool, contextShare: Double?) -> some View {
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
        AppStrings.Assistant.modelSummary(
            modelName: resolved?.model.label,
            effortName: supportsThinking ? effectiveReasoningEffort.displayName : nil,
            locale: locale)
    }

    private var modelAndThinkingAccessibilityLabel: LocalizedStringResource {
        AppStrings.Assistant.modelAccessibilityLabel(
            modelName: resolved?.model.label,
            effortName: supportsThinking ? effectiveReasoningEffort.displayName : nil)
    }

    private var modelAndThinkingHelp: LocalizedStringResource {
        AppStrings.Assistant.modelHelp(
            modelName: resolved?.model.label, providerName: resolved?.provider.name,
            effortName: supportsThinking ? effectiveReasoningEffort.displayName : nil)
    }

    private func isSelected(_ model: AIModel, on provider: ModelProvider) -> Bool {
        resolved?.provider.id == provider.id && resolved?.model.id == model.id
    }

    /// Sets this conversation's model and records the same choice as the
    /// app-wide fallback for conversations that have not chosen one.
    private func select(_ model: AIModel, on provider: ModelProvider) {
        let ref = AIModelRef(modelProviderID: provider.id, modelID: model.id)
        do {
            try app.assistantModelSelections.select(ref, for: conversation)
        } catch {
            window.assistantOperationError = error.localizedDescription
            return
        }
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
