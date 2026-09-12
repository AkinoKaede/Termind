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
    @State private var files = false
    @State private var photos = false
    @State private var camera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoTask: Task<Void, Never>?
    @State private var speechDraft = ""
    @State private var mcp = false
    @State private var contextDetails = false
    @State private var isSlashPanelDismissed = false
    @State private var slashPanelHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.locale) private var locale
    private var composer: ConversationComposerState { conversation.composer }
    private var recording: Bool { model.speech.isOwned(by: conversation.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            composerSurface
            if let error = composer.attachmentImportError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Dismiss", systemImage: "xmark") { composer.attachmentImportError = nil }
                }
            }
            if conversation.isCompacting { ProgressView("Compacting…") }
            if case .failed(let error) = conversation.compactionActivity?.state {
                Text(error).font(.caption).foregroundStyle(.red)
            }
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
        .sheet(isPresented: $mcp) {
            NavigationStack {
                MobileMCPSettings(ai: model.configuration, pro: pro)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done", systemImage: "checkmark") { mcp = false }.labelStyle(.iconOnly)
                        }
                    }
            }.mobileSheetPresentation(compact: true)
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
            .focused($focused)
            .disabled(recording)
            .padding(.horizontal, 4)
            .padding(.top, 4)

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
                    onBack: {
                        composer.draft = "/"
                        focused = true
                    },
                    onClose: {
                        isSlashPanelDismissed = true
                        focused = true
                    },
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
                focused = true
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
            Divider()
            Button("Voice Input", systemImage: "mic") { startSpeech() }.disabled(recording)
        } label: {
            Image(systemName: "plus").font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48).contentShape(.circle)
        }
        .accessibilityLabel("Add Attachment")
    }

    private var permissionMenu: some View {
        Menu {
            Picker(
                "Permissions",
                selection: Binding(
                    get: { model.configuration.resolve(conversation: conversation.permissionMode) },
                    set: {
                        conversation.permissionMode = $0
                        model.configuration.select($0)
                    })
            ) {
                ForEach(AgentPermissionMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
        } label: {
            Image(systemName: model.configuration.resolve(conversation: conversation.permissionMode).symbol)
                .font(.title3)
                .foregroundStyle(
                    model.configuration.resolve(conversation: conversation.permissionMode) == .fullAccess
                        ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
                )
                .frame(width: 48, height: 48).contentShape(.circle)
        }
        .accessibilityLabel("Permissions")
    }

    private var contextButton: some View {
        Button {
            contextDetails = true
        } label: {
            ContextRing(share: contextShare ?? 0, diameter: 28, lineWidth: 4)
                .frame(width: 48, height: 48).contentShape(.circle)
        }
        .accessibilityLabel("Context Tokens")
        .accessibilityValue(Text(conversation.contextEstimate.total, format: .number))
    }

    private var microphoneButton: some View {
        Button(action: startSpeech) {
            Label("Voice Input", systemImage: "mic").labelStyle(.iconOnly)
                .font(.system(size: 25, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 48, height: 48).contentShape(.circle)
        }
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
                    Section {
                        ContextBreakdownView(
                            estimate: conversation.contextEstimate,
                            contextWindow: resolved?.model.contextLength,
                            cachedInputTokens: conversation.usage?.cachedInputTokens ?? 0
                        )
                    }
                }
                Section("Model") { modelPicker }
                if let reasoningResolution {
                    Section("Reasoning") {
                        Picker("Reasoning", selection: $conversation.reasoningEffort) {
                            ForEach(reasoningResolution.supported, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { contextDetails = false }
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

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                modelPicker
                options
                badges
                Spacer()
                usage
            }
            VStack(alignment: .leading) {
                HStack {
                    modelPicker
                    options
                    Spacer()
                    usage
                }
                badges
            }
        }.font(.caption)
    }

    private var modelPicker: some View {
        Menu {
            Picker("Model", selection: Binding(get: { conversation.model }, set: { model.selectModel($0) })) {
                Text("Automatic").tag(nil as AIModelRef?)
                ForEach(model.configuration.enabledModelProviders) { provider in
                    ForEach(provider.assistantModels) { item in
                        Text("\(provider.name) · \(item.label)").tag(
                            AIModelRef(modelProviderID: provider.id, modelID: item.id) as AIModelRef?)
                    }
                }
            }
            if let resolved = model.configuration.resolve(conversation: conversation.model) {
                Picker("Reasoning", selection: $conversation.reasoningEffort) {
                    ForEach(
                        ModelCapabilityResolver.reasoning(model: resolved.model, provider: resolved.provider).supported,
                        id: \.self
                    ) { effort in
                        Text(effort.rawValue).tag(effort)
                    }
                }
            }
        } label: {
            if let resolved = model.configuration.resolve(conversation: conversation.model) {
                Label(resolved.model.label, systemImage: "cube").lineLimit(1)
            } else {
                Label("Model", systemImage: "cube")
            }
        }
    }

    private var options: some View {
        Menu {
            Picker(
                "Permissions",
                selection: Binding(
                    get: { model.configuration.resolve(conversation: conversation.permissionMode) },
                    set: {
                        conversation.permissionMode = $0
                        model.configuration.select($0)
                    })
            ) {
                ForEach(AgentPermissionMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            Toggle("Plan", isOn: $conversation.isPlanning)
            Menu("Skills", systemImage: "book.closed") {
                ForEach(model.skills.enabledSkills) { skill in
                    Button(skill.name, systemImage: "book.closed") { composer.armedSkillName = skill.effectiveName }
                }
            }
            Button("Compact", systemImage: "arrow.triangle.2.circlepath") { Task { await model.compact(conversation) } }
                .disabled(conversation.isStreaming)
            Button("MCP", systemImage: "network") { mcp = true }
        } label: {
            Image(systemName: model.configuration.resolve(conversation: conversation.permissionMode).symbol).frame(
                minWidth: 44, minHeight: 44
            ).contentShape(.rect)
        }
        .accessibilityLabel("Permissions")
    }

    @ViewBuilder private var badges: some View {
        if conversation.isPlanning {
            Button("Plan", systemImage: "lightbulb.max") { conversation.isPlanning = false }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        if let skill = composer.armedSkillName {
            Button(skill, systemImage: "book.closed") { composer.armedSkillName = nil }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private var usage: some View {
        Menu {
            Text("Context Tokens")
            Text(conversation.contextEstimate.total, format: .number)
            Button("Compact") { Task { await model.compact(conversation) } }
                .disabled(conversation.isStreaming || conversation.isCompacting)
        } label: {
            Label(conversation.contextEstimate.total.formatted(), systemImage: "chart.pie")
                .monospacedDigit().foregroundStyle(.secondary)
        }.accessibilityLabel("Context Tokens")
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

    private var slashModelChoices: [(argument: String, provider: ModelProvider, model: AIModel)] {
        model.configuration.enabledModelProviders.flatMap { provider in
            provider.assistantModels.map { item in
                ("\(provider.id.uuidString.lowercased()):\(item.id)", provider, item)
            }
        }
    }

    var availableCommands: [ChatSlashCommand] {
        var commands: [ChatSlashCommand] = []
        if !conversation.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "new", displayName: localized("New chat"),
                    summary: localized("Start a new conversation"), icon: .symbol("plus.bubble")
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
                    argumentHint: localized("what to emphasize")
                ))
        }
        if reasoningResolution?.supported.contains(where: { $0 != .off }) == true {
            commands.append(
                ChatSlashCommand(
                    id: "reasoning", displayName: localized("Reasoning"),
                    summary: localized("How hard the model thinks"), icon: .symbol("brain"),
                    argumentHint: localized("effort")
                ))
        }
        if !slashModelChoices.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "model", displayName: localized("Model"),
                    summary: localized("Switch the model for this conversation"), icon: .symbol("sparkles"),
                    argumentHint: localized("model")
                ))
        }
        if !model.configuration.mcpServers.isEmpty {
            commands.append(
                ChatSlashCommand(
                    id: "mcp", displayName: localized("MCP"),
                    summary: localized("Enable or disable MCP servers"), icon: .symbol("server.rack"),
                    argumentHint: localized("server")
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
        return commands.sorted { lhs, rhs in
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
            return option.id == "\(resolved.provider.id.uuidString.lowercased()):\(resolved.model.id)"
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
            composer.draft = ChatSlashCommandCompletion.accepted(row, takesArgument: hasOptions)
            if !hasOptions { _ = executeSlash() }
        case .option:
            composer.draft = ChatSlashCommandCompletion.accepted(row, takesArgument: false)
            _ = executeSlash()
        }
        focused = true
    }

    private func send() {
        if executeSlash() { return }
        model.send()
    }

    @discardableResult private func executeSlash() -> Bool {
        guard let command = ChatSlashCommandInput.parse(composer.draft),
            availableCommands.contains(where: { $0.id == command.name.lowercased() })
        else { return false }
        let argument: String
        if case .argument(_, let text) = command { argument = text } else { argument = "" }
        switch command.name.lowercased() {
        case "new":
            composer.draft = ""
            model.newConversation()
        case "plan":
            composer.draft = argument
            if argument.isEmpty {
                conversation.isPlanning.toggle()
            } else {
                conversation.isPlanning = true
                model.send()
            }
        case "compact":
            guard !conversation.isStreaming, !conversation.isCompacting else { return true }
            composer.draft = ""
            Task { await model.compact(conversation, instructions: argument) }
        case "mcp":
            if let id = UUID(uuidString: argument), let server = model.configuration.mcpServer(id),
                pro.require(.remoteMCP)
            {
                model.configuration.setServerEnabled(!server.isEnabled, for: id)
                composer.draft = ""
            } else if argument.isEmpty {
                composer.draft = "/mcp "
            }
        case "reasoning":
            if let effort = ReasoningEffort(rawValue: argument.lowercased()),
                let resolved = model.configuration.resolve(conversation: conversation.model),
                ModelCapabilityResolver.reasoning(model: resolved.model, provider: resolved.provider).supported
                    .contains(effort)
            {
                conversation.reasoningEffort = effort
                composer.draft = ""
            } else if argument.isEmpty {
                composer.draft = "/reasoning "
            }
        case "model":
            for provider in model.configuration.enabledModelProviders {
                if let item = provider.assistantModels.first(where: {
                    "\(provider.id.uuidString.lowercased()):\($0.id)" == argument
                }) {
                    model.selectModel(.init(modelProviderID: provider.id, modelID: item.id))
                    composer.draft = ""
                    return true
                }
            }
            if argument.isEmpty { composer.draft = "/model " }
        case "skill":
            if let choice = command.selection,
                model.skills.enabledSkills.contains(where: { $0.effectiveName == choice.name })
            {
                composer.armedSkillName = choice.name
                composer.draft = choice.remainder
                if !choice.remainder.isEmpty { model.send() }
            } else if argument.isEmpty {
                composer.draft = "/skill "
            }
        default: break
        }
        return true
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
        focused = false
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
