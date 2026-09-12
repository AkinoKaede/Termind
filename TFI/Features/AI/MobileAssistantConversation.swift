import AgentKit
import QuickLook
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import UniformTypeIdentifiers

struct MobileAssistantConversation: View {
    let app: MobileAppModel
    let model: MobileAssistantModel
    @Bindable var conversation: ConversationModel
    @State private var editing: ChatMessage?
    @State private var editedText = ""
    @State private var preview: URL?
    @State private var previewDirectory = FileManager.default.temporaryDirectory.appending(
        path: "Assistant-Previews/\(UUID().uuidString)")

    var body: some View {
        MobileNativeList(
            items: transcriptEntries,
            estimatedRowHeight: 132,
            refreshID: transcriptRefreshID,
            followsBottom: true
        ) { entry in
            transcriptRow(entry)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if conversation.isArchived {
                    Label("Archived conversations are read-only.", systemImage: "archivebox")
                    Button("Unarchive", systemImage: "tray.and.arrow.up") {
                        Task { await model.archive(conversation, archived: false) }
                    }
                } else {
                    if !conversation.tasks.isEmpty { taskList }
                    MobileAssistantInteraction(conversation: conversation, hosts: app.library)
                    MobileAssistantComposer(pro: app.pro, model: model, conversation: conversation)
                }
            }.padding(12).background(.bar)
        }
        .sheet(item: $editing) { message in
            NavigationStack {
                TextEditor(text: $editedText).padding()
                    .navigationTitle("Edit Message")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", systemImage: "xmark") { editing = nil }.labelStyle(.iconOnly)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send", systemImage: "arrow.up") {
                                Task { await model.edit(conversation, messageID: message.id, text: editedText) }
                                editing = nil
                            }.labelStyle(.iconOnly).disabled(
                                editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }.mobileSheetPresentation()
        }
        .quickLookPreview($preview)
        .onDisappear {
            try? FileManager.default.removeItem(at: previewDirectory)
        }
    }

    private var transcriptRefreshID: String {
        "\(conversation.id.uuidString):\(conversation.isArchived):\(conversation.isStreaming):\(conversation.timeline.count)"
    }

    private var transcriptEntries: [AssistantTranscriptEntry] {
        AssistantTranscriptEntry.items(
            timeline: conversation.timeline,
            isInterrupted: conversation.runState == .interrupted,
            canEdit: conversation.canEditUserMessage,
            canFork: conversation.canForkAssistantMessage
        )
    }

    private var taskList: some View {
        DisclosureGroup("Tasks") {
            ForEach(conversation.tasks) { task in
                Label(task.title, systemImage: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func transcriptRow(_ entry: AssistantTranscriptEntry) -> some View {
        switch entry.content {
        case .empty:
            ContentUnavailableView("Ask anything…", systemImage: "sparkles").frame(minHeight: 180)
        case .user(let message, _), .assistant(let message, _):
            messageRow(message)
        case .tool(let card):
            toolRow(card)
        case .work(let group):
            timelineRow(.work(group))
        case .command(let command):
            timelineRow(.command(command))
        case .plan(let plan):
            timelineRow(.plan(plan))
        case .compaction(let mark):
            timelineRow(.compaction(mark))
        case .compactionActivity(let activity):
            timelineRow(.compactionActivity(activity))
        case .interrupted:
            Label("This run was interrupted and was not resumed.", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func timelineRow(_ item: TimelineItem) -> some View {
        switch item {
        case .message(let message): messageRow(message)
        case .tool(let card): toolRow(card)
        case .plan(let card):
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.plan.title).font(.headline)
                    AssistantMessageBody(card.plan.body).textSelection(.enabled)
                    if card.outcome == .pending && !conversation.isArchived {
                        HStack {
                            Button("Implement", systemImage: "play") { model.implement(card, in: conversation) }
                                .disabled(conversation.isStreaming)
                            Button("Discard", systemImage: "xmark") {
                                conversation.resolvePlan(card.id, as: .discarded)
                            }
                        }
                    }
                }
            }
        case .work(let group):
            DisclosureGroup("Worked") {
                ForEach(group.items) { item in
                    switch item {
                    case .reasoning(let block): AssistantMessageBody(block.text).textSelection(.enabled)
                    case .message(let message): messageRow(message)
                    case .tool(let card): toolRow(card)
                    case .tools(let batch):
                        if let reasoning = batch.reasoning { AssistantMessageBody(reasoning.markdown) }
                        ForEach(batch.cards) { card in toolRow(card) }
                    }
                }
            }
        case .command(let command): Text(command.command).font(.body.monospaced()).textSelection(.enabled)
        case .compactionActivity: ProgressView("Compacting…")
        case .compaction(let mark):
            Label("Compacted", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                .accessibilityValue(Text(mark.summarizedTokens, format: .number))
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role != .user {
                Text("Assistant").font(.caption).foregroundStyle(.secondary)
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup("Thinking") {
                    ForEach(message.reasoning) { block in AssistantMessageBody(block.text).textSelection(.enabled) }
                }
            }
            if !message.text.isEmpty {
                if message.role == .user {
                    HStack {
                        Spacer(minLength: 44)
                        AssistantMessageBody(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } else {
                    AssistantMessageBody(message.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(message.images) { image in
                Button {
                    open(data: image.data, name: image.label)
                } label: {
                    if let uiImage = UIImage(data: image.data) {
                        Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 220).clipShape(
                            .rect(cornerRadius: 12))
                    } else {
                        Label(image.label, systemImage: "photo")
                    }
                }.buttonStyle(.plain)
            }
            ForEach(message.contextChips) { chip in
                if let attachment = chip.attachment {
                    Button {
                        open(data: attachment.data, name: attachment.suggestedFilename)
                    } label: {
                        Label(chip.label, systemImage: "doc")
                    }
                }
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            ShareLink(item: message.text)
            if conversation.canEditUserMessage(message.id) {
                Button("Edit", systemImage: "pencil") {
                    editedText = message.text
                    editing = message
                }
            }
            if conversation.canForkAssistantMessage(message.id) {
                Button("Fork Conversation", systemImage: "arrow.triangle.branch") {
                    Task { await model.fork(conversation, at: message.id) }
                }
            }
        }
    }

    private func toolRow(_ card: AgentToolCard) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.descriptor.summary).font(.caption)
                Text(card.invocation.call.arguments.displayText).font(.caption.monospaced()).textSelection(.enabled)
                if let result = card.result {
                    AssistantToolDetails(items: detailItems(card, result: result))
                }
            }
        } label: {
            HStack {
                Image(systemName: card.descriptor.presentation?.symbol ?? "wrench.and.screwdriver")
                Text(card.descriptor.name)
                Spacer()
                if !card.state.isTerminal {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: card.state == .completed ? "checkmark.circle" : "exclamationmark.circle")
                }
            }.font(.callout)
        }
    }

    private func detailItems(_ card: AgentToolCard, result: AgentToolResult) -> [AgentToolDetail.Item] {
        let raw = result.untrustedPayload ?? result.content
        guard card.descriptor.target != .mcp, let value = try? AgentJSONValue.decode(Data(raw.utf8)) else {
            return [.text(.init(text: raw, style: .monospaced))]
        }
        let presenter =
            card.descriptor.presentation?.presenterID.flatMap { TermindAgentTools.presenter(id: $0) }
            ?? TermindAgentTools.legacyPresenter(forToolNamed: card.descriptor.name)
        return presenter?.present(
            .init(result: value, arguments: card.invocation.call.arguments.objectValue ?? [:], locale: .current))
            ?? AgentToolDetailFormatting.genericItems(value, locale: .current)
    }

    private func open(data: Data, name: String) {
        do {
            let folder = previewDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = (name as NSString).lastPathComponent
            let url = folder.appending(
                path: filename.isEmpty || filename == "." || filename == ".." ? "Attachment" : filename)
            try data.write(to: url, options: .atomic)
            preview = url
        } catch { model.error = error.localizedDescription }
    }
}
