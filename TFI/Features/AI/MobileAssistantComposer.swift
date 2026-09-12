import AVFoundation
import AgentKit
import PhotosUI
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation

struct MobileAssistantComposer: View {
    let pro: ProAccessController
    let model: MobileAssistantModel
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
        model: MobileAssistantModel,
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
        VStack(alignment: .leading, spacing: 10) {
            composerSurface
            ForEach(conversation.pendingSteering) { pending in
                HStack {
                    Text(pending.draft).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Edit", systemImage: "pencil") { conversation.returnSteeringToDraft(pending.id) }
                }
            }
        }
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
            "Attachment Error",
            isPresented: Binding(
                get: { composer.attachmentImportError != nil },
                set: { if !$0 { composer.attachmentImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
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
                if let data { conversation.importAttachmentImages([data], label: String(localized: "Photo")) }
            }.ignoresSafeArea()
        }
        .alert(
            model.speech.error?.title ?? "Transcription Failed",
            isPresented: Binding(
                get: { model.speech.errorOwnerID == conversation.id },
                set: { if !$0 { model.speech.dismissError(ownerID: conversation.id) } })
        ) {
            if model.speech.error?.offersSystemSettings == true {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("OK") { model.speech.dismissError(ownerID: conversation.id) }
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
            Button("Send", action: submitFromKeyboard)
                .keyboardShortcut(MobileShortcut.send)
                .disabled(!canSend)
            Button("Stop", action: conversation.stop)
                .keyboardShortcut(MobileShortcut.stop)
                .disabled(!conversation.isStreaming)
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
                "Ask anything…", text: Binding(get: { composer.draft }, set: { composer.draft = $0 }),
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
                    recordingControls
                        .transition(.opacity)
                } else {
                    standardControls
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: showsTranscriptionControls)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
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
    private var recordingControls: some View {
        switch model.speech.phase {
        case .recording:
            speechControls {
                SpeechWaveformView(
                    samples: model.speech.levelSamples,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityLabel(Text("Recording"))
            }
        case .transcribing:
            speechControls {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Transcribing"))
            }
        case .idle:
            EmptyView()
        }
    }

    private func speechControls<Status: View>(@ViewBuilder status: () -> Status) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                composer.draft = speechDraft
                model.speech.cancel(ownerID: conversation.id)
                activeFocus.wrappedValue = true
            } label: {
                Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly)
                    .mobileComposerControlIcon()
            }
            .buttonStyle(.plain)
            status()
            Button {
                model.speech.stop(ownerID: conversation.id)
            } label: {
                Label("Done", systemImage: "stop.fill").labelStyle(.iconOnly)
                    .mobileComposerControlIcon()
            }
            .buttonStyle(.plain)
            .disabled(model.speech.phase != .recording)
        }
        .frame(minHeight: 48)
    }

    private var addMenu: some View {
        Menu {
            Button("Camera", systemImage: "camera") { openCamera() }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Photos", systemImage: "photo") { photos = true }
            Button("Files", systemImage: "doc") { files = true }
        } label: {
            Image(systemName: "plus")
                .mobileComposerControlIcon()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Attachment")
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
            Label("Permissions", systemImage: resolvedPermissionMode.symbol)
                .labelStyle(.iconOnly)
                .mobileComposerControlIcon(isDestructive: resolvedPermissionMode == .fullAccess)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel("Permissions")
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
                    Label("Voice Input", systemImage: "mic").labelStyle(.iconOnly)
                }
            }
            .mobileComposerControlIcon()
        }
        .buttonStyle(.plain)
        .disabled(
            !model.speech.canStart(for: conversation.id)
                || (ownsTranscription && model.speech.isRequestingAuthorization)
        )
        .accessibilityLabel(Text("Voice Input"))
    }

    @ViewBuilder private var primaryButton: some View {
        if conversation.isStreaming && !canSend {
            Button(action: conversation.stop) {
                Label("Stop", systemImage: "stop.circle.fill").labelStyle(.iconOnly)
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(.red)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
        } else {
            Button(action: send) {
                Label("Send", systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly)
                    .font(.system(size: 34, weight: .semibold)).frame(width: 48, height: 48).contentShape(.circle)
            }
            .disabled(!canSend)
        }
    }

    private var contextDetailsSheet: some View {
        NavigationStack {
            Form {
                if conversation.contextEstimate.total > 0 {
                    Section("Context") {
                        ContextBreakdownView(
                            estimate: conversation.contextEstimate,
                            contextWindow: resolved?.model.contextLength,
                            cachedInputTokens: conversation.usage?.cachedInputTokens ?? 0,
                            showsTitle: false
                        )
                    }
                }
                Section("Model") {
                    assistantModelPicker
                    if supportsThinking, let reasoningResolution {
                        Picker("Effort", selection: $conversation.reasoningEffort) {
                            ForEach(reasoningResolution.supported, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { contextDetails = false }
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
                    .accessibilityLabel(Text("Remove \(chip.label)"))
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
                    .accessibilityLabel(Text("Cancel importing \(pending.label)"))
                }
            }
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var assistantModelPicker: some View {
        if modelProviders.isEmpty {
            Text("No models configured").foregroundStyle(.secondary)
        } else {
            Picker(
                "Model",
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
            Button {
                conversation.isPlanning = false
            } label: {
                Label("Plan", systemImage: "lightbulb.max")
                    .labelStyle(.iconOnly)
                    .mobileComposerControlIcon(opacity: 0.62)
            }
            .buttonStyle(.plain)
        }
        if let skill = composer.armedSkillName {
            Button {
                composer.armedSkillName = nil
            } label: {
                Label(skill, systemImage: "book.closed")
                    .labelStyle(.iconOnly)
                    .mobileComposerControlIcon(opacity: 0.62)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skill \(skill) armed, remove"))
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

    private var modelAndEffortAccessibilityLabel: String {
        guard let resolved else { return String(localized: "Model, no model configured") }
        guard supportsThinking else { return String(localized: "Model \(resolved.model.label)") }
        return String(
            localized: "Model \(resolved.model.label), effort \(effectiveReasoningEffort.displayName)"
        )
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

    private func localized(_ resource: String.LocalizationValue) -> String {
        let candidates = [locale.identifier, locale.language.languageCode?.identifier].compactMap { $0 }
        let bundle =
            candidates.lazy.compactMap { identifier in
                Bundle.main.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:))
            }.first ?? .main
        return String(localized: resource, bundle: bundle, locale: locale)
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
            authorizeRemoteMCP: { pro.require(.remoteMCP) },
            localized: localized
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
            guard !Task.isCancelled, let pending = conversation.beginAttachmentImport(label: String(localized: "Photo"))
            else { break }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                let chip = try await ContextAttachmentImporter.importImage(
                    data: data, label: String(localized: "Photo"))
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
            await model.speech.start(ownerID: conversation.id) { text, _ in
                guard model.conversation.id == conversation.id else { return }
                _ = conversation.applyTranscription(text, sendAfterTranscription: false, send: {})
            }
        }
    }

    private func openCamera() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                camera = true
            } else {
                composer.attachmentImportError = String(localized: "Allow camera access in Settings to take a photo.")
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
