import AppKit
import SwiftUI

// MARK: - Context chips

/// The row of user-visible attachments sent to the LLM endpoint.
///
/// This is the trust surface of the whole feature. BYOK means the user's own key
/// pays for — and is exposed to — whatever we upload. Host and directory are
/// pinned; everything else the user added by hand can be taken back off. The
/// setting-disclosed, token-sanitized Shell Integration environment is not a chip.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var draftBeforeTranscription = ""

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
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    let disallowed: EventModifiers = [.control, .option]
                    guard press.modifiers.intersection(disallowed).isEmpty else { return .ignored }
                    sendDraft()
                    return .handled
                }

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
        .padding(Metrics.Space.l)
        .background(.bar)
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

    private var standardControls: some View {
        HStack(spacing: Metrics.Space.s) {
            ViewThatFits(in: .horizontal) {
                composerMenus(compact: false)
                composerMenus(compact: true)
            }
            .frame(maxWidth: .infinity)

            transcribeButton
            if conversation.isStreaming {
                sendButton(
                    enabled: !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: sendDraft
                )
                .help(Text("Queue message for the running agent"))
                Button(action: conversation.stop) {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 32, height: 32)
                .help(Text("Stop current run"))
            } else {
                sendButton(
                    enabled: !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: sendDraft
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
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

    private func sendButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Send", systemImage: "arrow.up.circle.fill")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 26, weight: .semibold))
        .frame(width: 32, height: 32)
        .contentShape(.circle)
        .disabled(!enabled)
        .help(Text("Send — ⌘⏎"))
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
        if conversation.isStreaming {
            conversation.submitSteeringDraft()
            return
        }
        if let onSend {
            onSend()
        } else {
            app.sendAgentDraft(conversation)
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
        app.ai.select(ref)
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
