import AVFoundation
import AgentKit
import PhotosUI
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation

private struct MobileAssistantInteractionSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background {
                // Keep the material in its own view. Applying it as a background style
                // gives descendants a vibrant foreground that can hide secondary text.
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial)
                    .ignoresSafeArea(.keyboard)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}

extension View {
    func mobileAssistantInteractionSurface() -> some View {
        modifier(MobileAssistantInteractionSurface())
    }
}

private struct MobileDismissibleComposerBadge: View {
    let symbol: String
    let help: Text
    let accessibilityLabel: Text
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isHovering ? "xmark" : symbol)
                .contentTransition(.symbolEffect(.replace))
                .mobileComposerControlIcon(opacity: 0.62)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MobileAssistantComposer: View {
    let pro: ProAccessController
    let model: MobileAssistantSceneModel
    @Bindable var conversation: ConversationModel
    let focus: FocusState<Bool>.Binding?
    let focusRequest: Int?
    let focusRequestHandled: (Int) -> Void
    @State private var files = false
    @State private var photos = false
    @State private var camera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoTask: Task<Void, Never>?
    @State private var speechDraft = ""
    @State private var contextDetails = false
    @State private var isSlashPanelDismissed = false
    @State private var slashPanelHeight: CGFloat = 0
    private let slashRegistry = ChatSlashCommandRegistry.standard()
    @FocusState private var localFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private var composer: ConversationComposerState { conversation.composer }
    private var ownsTranscription: Bool { model.speech.isOwned(by: conversation.id) }
    private var showsTranscriptionControls: Bool {
        ownsTranscription && model.speech.phase != .idle
    }
    private var activeFocus: FocusState<Bool>.Binding { focus ?? $localFocus }

    init(
        pro: ProAccessController,
        model: MobileAssistantSceneModel,
        conversation: ConversationModel,
        focus: FocusState<Bool>.Binding? = nil,
        focusRequest: Int? = nil,
        focusRequestHandled: @escaping (Int) -> Void = { _ in }
    ) {
        self.pro = pro
        self.model = model
        self.conversation = conversation
        self.focus = focus
        self.focusRequest = focusRequest
        self.focusRequestHandled = focusRequestHandled
    }

    var body: some View {
        composerSurface
            .sheet(isPresented: $contextDetails) { contextDetailsSheet }
            .fileImporter(
                isPresented: $files, allowedContentTypes: ContextAttachmentImporter.supportedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): conversation.importAttachmentFiles(urls)
                case .failure(let error): composer.attachmentImportError = error.localizedDescription
                }
            }
            .alert(
                AppStrings.Assistant.attachmentError,
                isPresented: Binding(
                    get: { composer.attachmentImportError != nil },
                    set: { if !$0 { composer.attachmentImportError = nil } }
                )
            ) {
                Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {}
            } message: {
                Text(composer.attachmentImportError ?? "")
            }
            .photosPicker(
                isPresented: $photos, selection: $photoItems,
                maxSelectionCount: max(1, 20 - composer.attachments.count - composer.pendingAttachments.count),
                matching: .images
            )
            .onChange(of: photoItems) { _, items in
                photoTask?.cancel()
                photoTask = Task { await importPhotos(items) }
            }
            .fullScreenCover(isPresented: $camera) {
                MobileAssistantCamera { data in
                    camera = false
                    if let data {
                        conversation.importAttachmentImages(
                            [data], label: String(localized: AppStrings.Assistant.photo))
                    }
                }.ignoresSafeArea()
            }
            .alert(
                model.speech.error?.title ?? localized(AppStrings.Assistant.transcriptionFailed),
                isPresented: Binding(
                    get: { model.speech.errorOwnerID == conversation.id },
                    set: { if !$0 { model.speech.dismissError(ownerID: conversation.id) } })
            ) {
                if model.speech.error?.offersSystemSettings == true {
                    Button(AppStrings.Navigation.settings.swiftUIKey) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button(AppStrings.Common.ok.swiftUIKey) { model.speech.dismissError(ownerID: conversation.id) }
            } message: {
                Text(model.speech.error?.message ?? "")
            }
            .onDisappear {
                photoTask?.cancel()
                model.speech.cancel(ownerID: conversation.id)
            }
            .task(id: focusRequest) {
                guard let focusRequest else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                activeFocus.wrappedValue = true
                focusRequestHandled(focusRequest)
            }
            .onAppear(perform: normalizeReasoningEffort)
            .onChange(of: reasoningResolution) { _, _ in normalizeReasoningEffort() }
            .background { keyboardShortcuts }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button(AppStrings.Assistant.send.swiftUIKey, action: submitFromKeyboard)
                .keyboardShortcut(MobileShortcut.send)
                .disabled(!canSend)
            Button(AppStrings.Common.stop.swiftUIKey, action: conversation.stop)
                .keyboardShortcut(MobileShortcut.stop)
                .disabled(!conversation.isAgentRunActive)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var composerSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !composer.attachments.isEmpty || !composer.pendingAttachments.isEmpty {
                attachmentRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            TextField(
                AppStrings.Assistant.prompt.swiftUIKey,
                text: Bindable(composer).projectedValue.draft,
                axis: .vertical
            )
            .lineLimit(1...6)
            .focused(activeFocus)
            .disabled(ownsTranscription)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .submitLabel(.send)
            .onSubmit(submitFromKeyboard)
            .onKeyPress(.escape, phases: .down) { _ in
                guard !slashCompletion.isEmpty, !isSlashPanelDismissed else { return .ignored }
                isSlashPanelDismissed = true
                return .handled
            }

            ZStack {
                if showsTranscriptionControls {
                    transcriptionControls(phase: model.speech.phase)
                        .transition(.opacity)
                } else {
                    standardControls
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: showsTranscriptionControls)
        }
        .mobileAssistantInteractionSurface()
        .overlay(alignment: .top) {
            if !slashCompletion.isEmpty, !isSlashPanelDismissed {
                MobileSlashCommandPanel(
                    completion: slashCompletion,
                    contextShare: contextShare,
                    hasOptions: { !slashOptions($0).isEmpty },
                    trailingText: slashTrailingText,
                    isCurrent: isCurrentSlashOption,
                    onSelect: acceptSlashRow
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    slashPanelHeight = height
                }
                .offset(y: -(slashPanelHeight + 8))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(20)
            }
        }
        .padding(.top, !slashCompletion.isEmpty && !isSlashPanelDismissed ? slashPanelHeight + 8 : 0)
        .animation(.snappy(duration: 0.2), value: slashCompletion.rows.map(\.id))
        .onChange(of: composer.draft) { _, _ in isSlashPanelDismissed = false }
    }

    private var standardControls: some View {
        HStack(alignment: .center, spacing: 2) {
            addMenu
            permissionMenu
            badges
            Spacer(minLength: 4)
            contextButton
            microphoneButton
            primaryButton
        }
        .frame(minHeight: 48)
    }

    @ViewBuilder
    func transcriptionControls(phase: SpeechTranscriptionCoordinator.Phase) -> some View {
        switch phase {
        case .recording:
            speechControls(phase: phase) {
                SpeechWaveformView(
                    samples: model.speech.levelSamples,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityLabel(Text(AppStrings.Assistant.recording))
            }
        case .transcribing:
            speechControls(phase: phase) {
                Text(AppStrings.Assistant.transcribing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        case .idle:
            EmptyView()
        }
    }

    private func speechControls<Status: View>(
        phase: SpeechTranscriptionCoordinator.Phase, @ViewBuilder status: () -> Status
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                composer.draft = speechDraft
                model.speech.cancel(ownerID: conversation.id)
                activeFocus.wrappedValue = true
            } label: {
                Label(AppStrings.Assistant.cancelTranscription.swiftUIKey, systemImage: "xmark").labelStyle(.iconOnly)
                    .mobileComposerControlIcon()
            }
            .buttonStyle(.plain)
            status()
            if phase == .recording {
                Button {
                    model.speech.stop(ownerID: conversation.id)
                } label: {
                    Label(AppStrings.Assistant.stopRecording.swiftUIKey, systemImage: "stop.fill").labelStyle(.iconOnly)
                        .mobileComposerControlIcon()
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .frame(width: 48, height: 48)
                    .accessibilityLabel(Text(AppStrings.Assistant.transcribing))
            }
            sendButton(enabled: phase == .recording) {
                model.speech.stop(ownerID: conversation.id, sendAfterTranscription: true)
            }
        }
        .frame(minHeight: 48)
    }

    private var addMenu: some View {
        Menu {
            Button(AppStrings.Assistant.camera.swiftUIKey, systemImage: "camera") { openCamera() }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button(AppStrings.Assistant.photos.swiftUIKey, systemImage: "photo") { photos = true }
            Button(AppStrings.Assistant.files.swiftUIKey, systemImage: "doc") { files = true }
        } label: {
            Image(systemName: "plus")
                .mobileComposerControlIcon()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppStrings.Assistant.addAttachment.swiftUIKey)
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(AgentPermissionMode.allCases) { mode in
                Button(role: mode == .fullAccess ? .destructive : nil) {
                    conversation.permissionMode = mode
                    model.configuration.select(mode)
                } label: {
                    Label(
                        mode.displayName,
                        systemImage: mode == resolvedPermissionMode ? "checkmark" : mode.symbol
                    )
                }
            }
        } label: {
            Label(AppStrings.Assistant.permissions.swiftUIKey, systemImage: resolvedPermissionMode.symbol)
                .labelStyle(.iconOnly)
                .mobileComposerControlIcon(isDestructive: resolvedPermissionMode == .fullAccess)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(AppStrings.Assistant.permissions.swiftUIKey)
    }

    private var resolvedPermissionMode: AgentPermissionMode {
        model.configuration.resolve(conversation: conversation.permissionMode)
    }

    private var contextButton: some View {
        Button {
            contextDetails = true
        } label: {
            ContextRing(share: contextShare ?? 0, diameter: 28, lineWidth: 4)
                .frame(width: 48, height: 48).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(modelAndEffortAccessibilityLabel))
        .accessibilityValue(Text(conversation.contextEstimate.total, format: .number))
    }

    private var microphoneButton: some View {
        Button(action: startSpeech) {
            Group {
                if ownsTranscription && model.speech.isRequestingAuthorization {
                    ProgressView().controlSize(.small)
                } else {
                    Label(AppStrings.Assistant.voiceInput.swiftUIKey, systemImage: "mic").labelStyle(.iconOnly)
                }
            }
            .mobileComposerControlIcon()
        }
        .buttonStyle(.plain)
        .disabled(
            !model.speech.canStart(for: conversation.id)
                || (ownsTranscription && model.speech.isRequestingAuthorization)
        )
        .accessibilityLabel(Text(AppStrings.Assistant.voiceInput))
    }

    @ViewBuilder private var primaryButton: some View {
        if conversation.isPreparingAgentRun || (conversation.isStreaming && !canSend) {
            Button(action: conversation.stop) {
                Label(AppStrings.Common.stop.swiftUIKey, systemImage: "stop.circle.fill").labelStyle(.iconOnly)
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(.red)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
        } else {
            sendButton(enabled: canSend, action: send)
        }
    }

    private func sendButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(AppStrings.Assistant.send.swiftUIKey, systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly)
                .font(.system(size: 34, weight: .semibold)).frame(width: 48, height: 48).contentShape(.circle)
        }
        .disabled(!enabled)
    }

    private var contextDetailsSheet: some View {
        NavigationStack {
            Form {
                if conversation.contextEstimate.total > 0 {
                    Section(AppStrings.Assistant.context.swiftUIKey) {
                        ContextBreakdownView(
                            estimate: conversation.contextEstimate,
                            contextWindow: resolved?.model.contextLength,
                            cachedInputTokens: conversation.usage?.cachedInputTokens ?? 0,
                            showsTitle: false
                        )
                    }
                }
                Section(AppStrings.Assistant.model.swiftUIKey) {
                    assistantModelPicker
                    if supportsThinking, let reasoningResolution {
                        Picker(AppStrings.Assistant.effort.swiftUIKey, selection: $conversation.reasoningEffort) {
                            ForEach(reasoningResolution.supported, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppStrings.Assistant.model.swiftUIKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppStrings.Common.done.swiftUIKey, systemImage: "checkmark") { contextDetails = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                }
            }
        }
        .mobileSheetPresentation(compact: true)
    }

    private var canSend: Bool {
        composer.pendingAttachments.isEmpty && !conversation.isCompacting
            && (!composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !composer.attachments.isEmpty)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(composer.attachments) { chip in
                    Button {
                        conversation.detach(chip.id)
                    } label: {
                        HStack(spacing: 6) {
                            if let image = chip.image, let ui = UIImage(data: image.data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                                    .frame(width: 24, height: 24).clipShape(.rect(cornerRadius: 6))
                            } else {
                                Image(systemName: chip.kind.symbol).font(.caption)
                            }
                            Text(chip.label).font(.caption).lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.55))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(minHeight: 44)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                        .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppStrings.Common.removeNamed(chip.label)))
                }
                ForEach(composer.pendingAttachments) { pending in
                    Button {
                        conversation.cancelAttachmentImport(pending.id)
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(pending.label).font(.caption).lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.55))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(minHeight: 44)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                        .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppStrings.Assistant.cancelImporting(pending.label)))
                }
            }
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var assistantModelPicker: some View {
        if modelProviders.isEmpty {
            Text(AppStrings.Assistant.noModelsConfigured).foregroundStyle(.secondary)
        } else {
            Picker(
                AppStrings.Assistant.model.swiftUIKey,
                selection: Binding(
                    get: { resolvedModelRef },
                    set: { if let value = $0 { model.selectModel(value) } })
            ) {
                ForEach(modelProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.assistantModels) { item in
                            Text(item.label).tag(
                                AIModelRef(modelProviderID: provider.id, modelID: item.id) as AIModelRef?)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var badges: some View {
        if conversation.isPlanning {
            MobileDismissibleComposerBadge(
                symbol: "lightbulb.max",
                help: Text(AppStrings.Assistant.planModeClickToTurnOff),
                accessibilityLabel: Text(AppStrings.Assistant.planModeOnTurnOff)
            ) {
                conversation.isPlanning = false
            }
        }
        if let skill = composer.armedSkillName {
            MobileDismissibleComposerBadge(
                symbol: "book.closed",
                help: Text(AppStrings.Assistant.armedSkillHelp(skill)),
                accessibilityLabel: Text(AppStrings.Assistant.skillArmedRemove(skill))
            ) {
                composer.armedSkillName = nil
            }
        }
    }

    private var modelProviders: [ModelProvider] {
        model.configuration.enabledModelProviders.filter { !$0.assistantModels.isEmpty }
    }

    private var resolvedModelRef: AIModelRef? {
        guard let resolved else { return nil }
        return AIModelRef(modelProviderID: resolved.provider.id, modelID: resolved.model.id)
    }

    private var resolved: (provider: ModelProvider, model: AIModel)? {
        model.configuration.resolve(conversation: conversation.model)
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

    private var modelAndEffortAccessibilityLabel: LocalizedStringResource {
        AppStrings.Assistant.modelAccessibilityLabel(
            modelName: resolved?.model.label,
            effortName: supportsThinking ? effectiveReasoningEffort.displayName : nil)
    }

    var availableCommands: [ChatSlashCommand] {
        slashRegistry.commands(in: slashContext)
    }

    private func slashOptions(_ command: ChatSlashCommand) -> [ChatSlashCommand.Option] {
        slashRegistry.options(for: command, in: slashContext)
    }

    private var slashCompletion: ChatSlashCommandCompletion {
        slashRegistry.completion(for: composer.draft, in: slashContext)
    }

    private var contextShare: Double? {
        guard conversation.contextEstimate.total > 0 else { return nil }
        return conversation.contextEstimate.share(of: resolved?.model.contextLength)
    }

    private func slashTrailingText(_ row: ChatSlashCommandCompletion.Row) -> String? {
        slashRegistry.trailingText(for: row, in: slashContext)
    }

    private func isCurrentSlashOption(_ row: ChatSlashCommandCompletion.Row) -> Bool {
        slashRegistry.isCurrent(row, in: slashContext)
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        AppLocalization.resolve(resource, locale: locale)
    }

    private func acceptSlashRow(_ row: ChatSlashCommandCompletion.Row) {
        switch row {
        case .command(let command):
            let hasOptions = !slashOptions(command).isEmpty
            composer.draft = ChatSlashCommandCompletion.accepted(
                row, takesArgument: hasOptions, in: composer.draft
            )
            if !hasOptions { _ = executeSlash() }
        case .option:
            composer.draft = ChatSlashCommandCompletion.accepted(
                row, takesArgument: false, in: composer.draft
            )
            _ = executeSlash()
        }
        activeFocus.wrappedValue = true
    }

    private func send() {
        if executeSlash() { return }
        model.send()
    }

    private func submitFromKeyboard() {
        if !isSlashPanelDismissed, let first = slashCompletion.rows.first {
            acceptSlashRow(first)
        } else {
            send()
        }
    }

    @discardableResult private func executeSlash() -> Bool {
        slashRegistry.perform(draft: composer.draft, in: slashContext)
    }

    private var slashContext: ChatSlashCommandContext {
        ChatSlashCommandContext(
            platform: .mobile,
            conversation: conversation,
            configuration: model.configuration,
            skills: model.skills,
            compact: { instructions in
                Task { await model.compact(conversation, instructions: instructions) }
            },
            send: model.send,
            selectModel: { model.selectModel($0) },
            authorizeRemoteMCP: { true },
            localized: { AppLocalization.string($0, locale: locale) }
        )
    }

    private func normalizeReasoningEffort() {
        let normalized = effectiveReasoningEffort
        if conversation.reasoningEffort != normalized {
            conversation.reasoningEffort = normalized
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard !Task.isCancelled,
                let pending = conversation.beginAttachmentImport(label: String(localized: AppStrings.Assistant.photo))
            else { break }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                let chip = try await conversation.attachmentLoader.image(
                    data, String(localized: AppStrings.Assistant.photo))
                try Task.checkCancellation()
                conversation.finishAttachmentImport(pending.id, with: chip)
            } catch is CancellationError { conversation.cancelAttachmentImport(pending.id) } catch {
                conversation.failAttachmentImport(pending.id, message: error.localizedDescription)
            }
        }
    }

    private func startSpeech() {
        speechDraft = composer.draft
        activeFocus.wrappedValue = false
        Task {
            await model.speech.start(ownerID: conversation.id, completion: applySpeechTranscript)
        }
    }

    func applySpeechTranscript(_ text: String, sendAfterTranscription: Bool) {
        guard model.conversation.id == conversation.id else { return }
        _ = conversation.applyTranscription(text, sendAfterTranscription: sendAfterTranscription, send: send)
    }

    private func openCamera() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                camera = true
            } else {
                composer.attachmentImportError = String(
                    localized: AppStrings.Assistant.allowCameraAccessInSettingsToTakeAPhoto)
            }
        }
    }
}

private struct MobileComposerControlIconModifier: ViewModifier {
    let isDestructive: Bool
    let opacity: Double

    private var tint: Color {
        isDestructive ? .red : Color.primary.opacity(opacity)
    }

    func body(content: Content) -> some View {
        content
            .font(.title3.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .frame(width: 48, height: 48, alignment: .center)
            .contentShape(.circle)
    }
}

extension View {
    fileprivate func mobileComposerControlIcon(isDestructive: Bool = false, opacity: Double = 0.75) -> some View {
        modifier(MobileComposerControlIconModifier(isDestructive: isDestructive, opacity: opacity))
    }
}
