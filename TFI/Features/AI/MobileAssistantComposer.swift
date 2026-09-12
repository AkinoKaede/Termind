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
    @FocusState private var localFocus: Bool
    @Environment(\.locale) private var locale
    private var composer: ConversationComposerState { conversation.composer }
    private var recording: Bool { model.speech.isOwned(by: conversation.id) }
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
            .disabled(recording)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .submitLabel(.send)
            .onSubmit(submitFromKeyboard)
            .onKeyPress(.escape, phases: .down) { _ in
                guard !slashCompletion.isEmpty, !isSlashPanelDismissed else { return .ignored }
                isSlashPanelDismissed = true
                return .handled
            }

            if recording { recordingControls } else { standardControls }
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
        HStack(spacing: 2) {
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

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Button {
                composer.draft = speechDraft
                model.speech.cancel(ownerID: conversation.id)
                activeFocus.wrappedValue = true
            } label: {
                Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
            if model.speech.isRequestingAuthorization || model.speech.phase == .transcribing {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").symbolEffect(.variableColor)
                    Text("Recording…").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            Button {
                model.speech.stop(ownerID: conversation.id)
            } label: {
                Label("Done", systemImage: "stop.fill").labelStyle(.iconOnly)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
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
            Image(systemName: "plus").font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48).contentShape(.circle)
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
                .font(.title3)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(
                    resolvedPermissionMode == .fullAccess
                        ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)
                )
                .frame(width: 48, height: 48).contentShape(.circle)
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
            Label("Voice Input", systemImage: "mic").labelStyle(.iconOnly)
                .font(.system(size: 25, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 48, height: 48).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!model.speech.canStart(for: conversation.id))
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
                    .frame(width: 48, height: 48)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        if let skill = composer.armedSkillName {
            Button {
                composer.armedSkillName = nil
            } label: {
                Label(skill, systemImage: "book.closed")
                    .labelStyle(.iconOnly)
                    .frame(width: 48, height: 48)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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

    private var slashModelChoices: [(argument: String, provider: ModelProvider, model: AIModel)] {
        model.configuration.enabledModelProviders.flatMap { provider in
            provider.assistantModels.map { item in
                (
                    ChatSlashCommand.argumentID(
                        scope: provider.id.uuidString.lowercased(), value: item.id
                    ),
                    provider,
                    item
                )
            }
        }
    }

    var availableCommands: [ChatSlashCommand] {
        var commands: [ChatSlashCommand] = []
        if !conversation.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "new", displayName: localized("New chat"),
                    summary: localized("Start a new conversation"), icon: .symbol("plus.bubble"),
                    isShownOnMobile: false
                ))
        }
        commands.append(
            ChatSlashCommand(
                id: "plan", displayName: localized("Plan mode"),
                summary: conversation.isPlanning
                    ? localized("Stop planning and act")
                    : localized("Research and propose before acting"),
                icon: .symbol("lightbulb.max"), argumentHint: localized("what to plan")
            ))
        if !conversation.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "compact", displayName: localized("Compact"),
                    summary: localized("Summarize older turns to free context"), icon: .contextRing,
                    argumentHint: localized("what to emphasize"), isShownOnMobile: true
                ))
        }
        if reasoningResolution?.supported.contains(where: { $0 != .off }) == true {
            commands.append(
                ChatSlashCommand(
                    id: "reasoning", displayName: localized("Reasoning"),
                    summary: localized("How hard the model thinks"), icon: .symbol("brain"),
                    argumentHint: localized("effort"), isShownOnMobile: false
                ))
        }
        if !slashModelChoices.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "model", displayName: localized("Model"),
                    summary: localized("Switch the model for this conversation"), icon: .symbol("sparkles"),
                    argumentHint: localized("model"), isShownOnMobile: false
                ))
        }
        if !model.configuration.mcpServers.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "mcp", displayName: localized("MCP"),
                    summary: localized("Enable or disable MCP servers"), icon: .symbol("server.rack"),
                    argumentHint: localized("server"), isShownOnMobile: false
                ))
        }
        if !model.skills.enabledSkills.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "skill", displayName: localized("Skill"),
                    summary: localized("Use an installed skill"), icon: .symbol("book.closed"),
                    argumentHint: localized("skill")
                ))
        }
        return commands.filter(\.isShownOnMobile).sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private func slashOptions(_ command: ChatSlashCommand) -> [ChatSlashCommand.Option] {
        switch command.id {
        case "model":
            return slashModelChoices.map { choice in
                .init(id: choice.argument, label: choice.model.label, detail: choice.provider.name)
            }
        case "reasoning":
            return reasoningResolution?.supported.map {
                .init(id: $0.rawValue, label: $0.displayName)
            } ?? []
        case "skill":
            return model.skills.enabledSkills.map {
                .init(id: $0.effectiveName, label: $0.displayTitle, detail: $0.summary)
            }
        case "mcp":
            return model.configuration.mcpServers.map {
                .init(id: $0.id.uuidString.lowercased(), label: $0.name)
            }
        default: return []
        }
    }

    private var slashCompletion: ChatSlashCommandCompletion {
        ChatSlashCommandCompletion.rows(
            draft: composer.draft, commands: availableCommands, options: slashOptions)
    }

    private var contextShare: Double? {
        guard conversation.contextEstimate.total > 0 else { return nil }
        return conversation.contextEstimate.share(of: resolved?.model.contextLength)
    }

    private func slashTrailingText(_ row: ChatSlashCommandCompletion.Row) -> String? {
        switch row {
        case .command(let command) where command.id == "reasoning":
            return effectiveReasoningEffort.displayName
        case .command(let command) where command.id == "model":
            return resolved?.model.label ?? localized("No model")
        case .option(let command, let option) where command.id == "mcp":
            guard let id = UUID(uuidString: option.id), let server = model.configuration.mcpServer(id) else {
                return nil
            }
            return server.isEnabled ? localized("Enabled") : localized("Disabled")
        case .option(let command, let option) where command.id == "skill":
            return option.id
        default:
            return nil
        }
    }

    private func isCurrentSlashOption(_ row: ChatSlashCommandCompletion.Row) -> Bool {
        guard case .option(let command, let option) = row else { return false }
        switch command.id {
        case "reasoning":
            return option.id == effectiveReasoningEffort.rawValue
        case "model":
            guard let resolved else { return false }
            return option.id
                == ChatSlashCommand.argumentID(
                    scope: resolved.provider.id.uuidString.lowercased(), value: resolved.model.id
                )
        case "skill":
            return option.id == composer.armedSkillName
        default:
            return false
        }
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
        guard let command = ChatSlashCommandInput.parse(composer.draft),
            availableCommands.contains(where: { $0.id == command.name.lowercased() })
        else { return false }
        let argument: String
        if case .argument(_, _, let text) = command { argument = text } else { argument = "" }
        switch command.name.lowercased() {
        case "new":
            composer.draft = command.leadingText
            model.newConversation()
        case "plan":
            if argument.isEmpty {
                conversation.isPlanning.toggle()
                composer.draft = command.leadingText
            } else {
                conversation.isPlanning = true
                composer.draft = command.leadingText + argument
                if command.leadingText.isEmpty { model.send() }
            }
        case "compact":
            guard !conversation.isStreaming, !conversation.isCompacting else { return true }
            composer.draft = command.leadingText
            Task { await model.compact(conversation, instructions: argument) }
        case "mcp":
            if let id = UUID(uuidString: argument), let server = model.configuration.mcpServer(id),
                pro.require(.remoteMCP)
            {
                model.configuration.setServerEnabled(!server.isEnabled, for: id)
                composer.draft = command.leadingText
            } else if argument.isEmpty {
                composer.draft = command.replacingCommand(with: "/mcp ")
            }
        case "reasoning":
            if let effort = ReasoningEffort(rawValue: argument.lowercased()),
                let resolved = model.configuration.resolve(conversation: conversation.model),
                ModelCapabilityResolver.reasoning(model: resolved.model, provider: resolved.provider).supported
                    .contains(effort)
            {
                conversation.reasoningEffort = effort
                composer.draft = command.leadingText
            } else if argument.isEmpty {
                composer.draft = command.replacingCommand(with: "/reasoning ")
            }
        case "model":
            for provider in model.configuration.enabledModelProviders {
                if let item = provider.assistantModels.first(where: {
                    ChatSlashCommand.argumentID(
                        scope: provider.id.uuidString.lowercased(), value: $0.id
                    ) == argument
                }) {
                    model.selectModel(.init(modelProviderID: provider.id, modelID: item.id))
                    composer.draft = command.leadingText
                    return true
                }
            }
            if argument.isEmpty { composer.draft = command.replacingCommand(with: "/model ") }
        case "skill":
            if let choice = command.selection,
                model.skills.enabledSkills.contains(where: { $0.effectiveName == choice.name })
            {
                composer.armedSkillName = choice.name
                composer.draft = command.leadingText + choice.remainder
                if command.leadingText.isEmpty, !choice.remainder.isEmpty { model.send() }
            } else if argument.isEmpty {
                composer.draft = command.replacingCommand(with: "/skill ")
            }
        default: break
        }
        return true
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
