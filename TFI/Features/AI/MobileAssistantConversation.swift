import AgentKit
import QuickLook
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import UniformTypeIdentifiers

private struct MobileConversationAttachmentDropModifier: ViewModifier {
    let conversation: ConversationModel
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay {
                    if isTargeted {
                        DropTargetOverlay(
                            presentation: DropTargetPresentation(
                                title: String(localized: AppStrings.Assistant.attachToChat),
                                detail: String(localized: AppStrings.Assistant.filesAndImages),
                                systemImage: "paperclip"
                            )
                        )
                    }
                }
                .contentShape(.rect)
                .onDrop(
                    of: [.fileURL, .image],
                    isTargeted: $isTargeted,
                    perform: receive
                )
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.16),
                    value: isTargeted
                )
        } else {
            content
        }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let kinds: Set<MobileDropKind> = [.files, .images]
        guard MobileDropPayloadLoader.accepts(providers, kinds: kinds) else { return false }
        Task {
            let payload = await MobileDropPayloadLoader.load(providers, kinds: kinds)
            if !payload.fileURLs.isEmpty {
                conversation.importAttachmentFiles(payload.fileURLs)
            }
            if !payload.images.isEmpty {
                conversation.importAttachmentImages(
                    payload.images, label: String(localized: AppStrings.Assistant.droppedImage)
                )
            }
            if !payload.failures.isEmpty {
                conversation.composer.attachmentImportError = [
                    conversation.composer.attachmentImportError,
                    payload.failures.joined(separator: "\n"),
                ]
                .compactMap { $0 }
                .joined(separator: "\n")
            }
        }
        return true
    }
}

extension View {
    fileprivate func mobileConversationAttachmentDropTarget(
        conversation: ConversationModel,
        isEnabled: Bool
    ) -> some View {
        modifier(
            MobileConversationAttachmentDropModifier(
                conversation: conversation,
                isEnabled: isEnabled
            )
        )
    }
}

/// Wraps message images while keeping every row anchored to the message role's edge.
///
/// An adaptive `LazyVGrid` reserves all columns that fit the available width, so a
/// partially filled user row starts in the first (leading) column. This layout only
/// reserves the columns used by each row, matching TFM's trailing image flow.
struct MobileAssistantImageFlowLayout: Layout {
    enum Alignment {
        case leading
        case trailing
    }

    struct Placement {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    let alignment: Alignment
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.enumerated().reduce(CGFloat.zero) { total, item in
            total + item.element.width + (item.offset == 0 ? 0 : spacing)
        }
        let width = proposal.width.map { max(0, $0) } ?? naturalWidth
        let placements = Self.placements(
            for: sizes,
            in: width,
            spacing: spacing,
            alignment: alignment
        )
        let height = placements.map { $0.origin.y + $0.size.height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let placements = Self.placements(
            for: subviews.map { $0.sizeThatFits(.unspecified) },
            in: bounds.width,
            spacing: spacing,
            alignment: alignment
        )
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    static func placements(
        for itemSizes: [CGSize],
        in availableWidth: CGFloat,
        spacing: CGFloat,
        alignment: Alignment
    ) -> [Placement] {
        struct Item {
            let index: Int
            let size: CGSize
        }
        struct Row {
            var items: [Item] = []
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        let availableWidth = max(0, availableWidth)
        var rows: [Row] = []
        var current = Row()

        for (index, itemSize) in itemSizes.enumerated() {
            let size = CGSize(width: min(itemSize.width, availableWidth), height: itemSize.height)
            let nextWidth = current.width + (current.items.isEmpty ? 0 : spacing) + size.width
            if !current.items.isEmpty, nextWidth > availableWidth {
                rows.append(current)
                current = Row()
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(Item(index: index, size: size))
        }
        if !current.items.isEmpty { rows.append(current) }

        var placements: [Placement] = []
        var y: CGFloat = 0
        for row in rows {
            var x = alignment == .trailing ? max(0, availableWidth - row.width) : 0
            for item in row.items {
                placements.append(
                    Placement(index: item.index, origin: CGPoint(x: x, y: y), size: item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
        return placements
    }
}

@MainActor
struct MobileAssistantAgentOriginPresentation: Equatable {
    let label: String
    let canNavigate: Bool

    init(
        origin: AgentMessageOrigin, source: ConversationModel?,
        locale: Locale = .current
    ) {
        let sourceTitle = source?.derivedTitle ?? origin.sourceTitle
        label =
            sourceTitle.map {
                AppLocalization.resolve(AppStrings.Assistant.agentFrom($0), locale: locale)
            } ?? AppLocalization.resolve(AppStrings.Assistant.agent, locale: locale)
        canNavigate = source != nil
    }
}

struct MobileAssistantAgentOriginButton: View {
    static let systemImage = "sparkles"

    let presentation: MobileAssistantAgentOriginPresentation
    let navigate: () -> Void

    var body: some View {
        Button(action: navigate) {
            Label(
                AppStrings.Assistant.agent.swiftUIKey,
                systemImage: Self.systemImage
            )
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!presentation.canNavigate)
        .accessibilityLabel(Text(presentation.label))
        .help(presentation.label)
        .accessibilityIdentifier("AssistantMessage.AgentOrigin")
    }
}

struct MobileAssistantUserBubble: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize(horizontal: true, vertical: false)
            content
        }
    }

    private var content: some View {
        MobileAssistantMarkdown(text: text)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                .tint.opacity(0.1),
                in: RoundedRectangle(
                    cornerRadius: AssistantTranscriptStyle.bubbleRadius,
                    style: .continuous
                )
            )
    }
}

struct MobileAssistantEditMessageTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.1), lineWidth: 1)
            }
    }
}

private struct MobileAssistantSteeringQueue: View {
    let conversation: ConversationModel

    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppStrings.Assistant.steering.swiftUIKey, systemImage: "arrow.turn.down.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(conversation.pendingSteering) { pending in
                        row(pending)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    rowsHeight = $0
                }
            }
            .frame(height: min(rowsHeight, 88))
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileAssistantInteractionSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Assistant.queuedMessages))
    }

    private func row(_ pending: PendingSteeringMessage) -> some View {
        Button {
            conversation.returnSteeringToDraft(pending.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pending.draft)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !pending.attachments.isEmpty {
                    Label("\(pending.attachments.count)", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    // Match the always-visible Permission control on iOS.
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppStrings.Assistant.unqueueMessage))
        .accessibilityHint(Text(AppStrings.Assistant.takeThisBackAndEditIt))
    }
}

/// Native list rows have independent hosting roots, so navigation must be injected here.
struct MobileAssistantTranscriptRowRoot<Content: View>: View {
    let navigate: @MainActor (AgentToolDetail.NavigationReference) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.assistantToolNavigation, navigate)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
    }
}

struct MobileAssistantConversation: View {
    let app: MobileAppModel
    let model: MobileAssistantSceneModel
    let conversation: ConversationModel
    let composerFocus: FocusState<Bool>.Binding
    let composerFocusRequest: Int?
    let composerFocusRequestHandled: (Int) -> Void
    @State private var editing: ChatMessage?
    @State private var editedText = ""
    @State private var presentation = AssistantTranscriptPresentationState()
    @State private var interactionHeight: CGFloat = 0
    @Environment(\.locale) private var locale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var preview: URL?
    @State private var previewDirectory = FileManager.default.temporaryDirectory.appending(
        path: "Assistant-Previews/\(UUID().uuidString)")

    private func navigateToToolReference(_ reference: AgentToolDetail.NavigationReference) {
        guard case .chat(let id) = reference,
            let target = model.library.conversation(id: id)
        else { return }
        model.select(target)
    }

    var body: some View {
        let entries = transcriptEntries
        let validPresentationIDs = entries.reduce(into: Set<UUID>()) { $0.formUnion($1.presentationIDs) }
        let revisions = Dictionary(
            uniqueKeysWithValues: entries.map {
                ($0.id, presentation.layoutRevision(for: $0.presentationIDs))
            })
        MobileRegionReader { regions in
            let panes = regions.assistant(interactionHeight: interactionHeight)
            MobilePaneLayout(frames: [panes.first, panes.second]) {
                MobileNativeList(
                    items: entries,
                    estimatedRowHeight: 132,
                    refreshID: transcriptRefreshID,
                    followsBottom: true,
                    surface: .plain,
                    rowRevision: { revisions[$0.id] ?? 0 },
                    prepareUpdate: { old, new, visible in
                        presentation.prepareWorkCompletionTransitions(from: old, to: new, visibleIDs: visible)
                    },
                    onViewportChange: { presentation.collapseWorkOutsideViewport(visibleIDs: $0) },
                    onTap: { composerFocus.wrappedValue = false }
                ) { entry in
                    MobileAssistantTranscriptRowRoot(navigate: navigateToToolReference) {
                        transcriptRow(entry)
                    }
                }
                .opacity(MobileContentRegions.isUsable(panes.first) ? 1 : 0)
                .allowsHitTesting(MobileContentRegions.isUsable(panes.first))
                .accessibilityHidden(!MobileContentRegions.isUsable(panes.first))
                .clipped()
                ScrollView {
                    bottomSurface
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            interactionHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .opacity(MobileContentRegions.isUsable(panes.second) ? 1 : 0)
                .allowsHitTesting(MobileContentRegions.isUsable(panes.second))
                .accessibilityHidden(!MobileContentRegions.isUsable(panes.second))
                .clipped()
            }
        }
        .environment(\.assistantToolNavigation, navigateToToolReference)
        .background(Color(uiColor: .systemBackground))
        .mobileConversationAttachmentDropTarget(
            conversation: conversation,
            isEnabled: acceptsAttachmentDrops
        )
        .sheet(item: $editing) { message in
            NavigationStack {
                MobileAssistantEditMessageTextEditor(text: $editedText)
                    .padding()
                    .navigationTitle(AppStrings.Assistant.editMessage.swiftUIKey)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark") { editing = nil }
                                .labelStyle(.iconOnly)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(AppStrings.Assistant.send.swiftUIKey, systemImage: "arrow.up") {
                                model.edit(conversation, messageID: message.id, text: editedText)
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
        .onChange(of: validPresentationIDs) { _, valid in
            presentation.prune(validTimelineIDs: valid)
        }
    }

    private var transcriptRefreshID: String {
        "\(conversation.id.uuidString):\(conversation.isArchived):\(conversation.isStreaming)"
    }

    private var acceptsAttachmentDrops: Bool {
        !conversation.isArchived
            && conversation.pendingApproval == nil
            && conversation.pendingUserInteraction == nil
    }

    private var transcriptEntries: [AssistantTranscriptEntry] {
        let availability = conversation.messageActionAvailability
        return AssistantTranscriptEntry.items(
            timeline: conversation.timeline,
            isInterrupted: conversation.runState == .interrupted,
            canEdit: availability.editable.contains,
            canFork: availability.forkable.contains
        )
    }

    @ViewBuilder private var bottomSurface: some View {
        bottomSurfaceContent
            .padding(12)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder private var bottomSurfaceContent: some View {
        if conversation.isArchived {
            archivedNotice
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                }
        } else if conversation.pendingApproval != nil || conversation.pendingUserInteraction != nil {
            MobileAssistantInteraction(conversation: conversation, hosts: app.library, speech: model.speech)
        } else {
            regularInteractionSurface
        }
    }

    private var regularInteractionSurface: some View {
        VStack(spacing: 8) {
            if !conversation.pendingSteering.isEmpty {
                MobileAssistantSteeringQueue(conversation: conversation)
            }
            MobileAssistantComposer(
                model: model,
                conversation: conversation,
                focus: composerFocus,
                focusRequest: composerFocusRequest,
                focusRequestHandled: composerFocusRequestHandled
            )
        }
    }

    private var archivedNotice: some View {
        ViewThatFits(in: .horizontal) {
            archivedNoticeContent
            VStack(alignment: .leading, spacing: 12) {
                archivedNoticeLabel
                unarchiveButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var archivedNoticeContent: some View {
        HStack(spacing: 12) {
            archivedNoticeLabel
            Spacer(minLength: 12)
            unarchiveButton
        }
    }

    private var archivedNoticeLabel: some View {
        Label(AppStrings.Assistant.archivedConversationsAreReadOnly.swiftUIKey, systemImage: "archivebox")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var unarchiveButton: some View {
        Button(AppStrings.Assistant.unarchive.swiftUIKey, systemImage: "arrow.uturn.backward") {
            Task { await model.archive(conversation, archived: false) }
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    @ViewBuilder private func transcriptRow(_ entry: AssistantTranscriptEntry) -> some View {
        switch entry.content {
        case .empty:
            VStack(alignment: .leading, spacing: 12) {
                Text(AppStrings.Assistant.startAConversation).font(.headline)
                Text(AppStrings.Assistant.askAQuestionOrDescribeWhatYouWantToDo).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
        case .user(let message, let canEdit):
            messageRow(message, canEdit: canEdit, canFork: false)
        case .assistant(let message, let canFork):
            messageRow(message, canEdit: false, canFork: canFork)
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
        case .failure(let failure):
            agentFailureRow(failure)
        case .interrupted:
            Label(AppStrings.Assistant.thisRunWasInterruptedAndWasNotResumed.swiftUIKey, systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func timelineRow(_ item: TimelineItem) -> some View {
        switch item {
        case .message(let message):
            messageRow(
                message, canEdit: conversation.canEditUserMessage(message.id),
                canFork: conversation.canForkAssistantMessage(message.id))
        case .tool(let card): toolRow(card)
        case .plan(let card):
            MobileAssistantPlanRow(
                card: card, presentation: presentation, readOnly: conversation.isArchived,
                isStreaming: conversation.isStreaming,
                implement: { model.implement(card, in: conversation) },
                discard: { conversation.resolvePlan(card.id, as: .discarded) }
            )
        case .work(let group):
            MobileAssistantWorkRow(group: group, presentation: presentation, hostName: hostName)
        case .command(let command): MobileAssistantCommandRow(command: command)
        case .compactionActivity(let activity): compactionActivityRow(activity)
        case .compaction(let mark):
            compactionRow(mark)
        case .failure(let failure):
            agentFailureRow(failure)
        }
    }

    private func compactionRow(_ mark: AgentCompactionMark) -> some View {
        HStack(spacing: 8) {
            compactionRule
            Label(
                AppLocalization.resolve(
                    AppStrings.Assistant.compactionSummary(
                        summarized: ContextBreakdownView.compact(mark.summarizedTokens),
                        retained: ContextBreakdownView.compact(mark.keptTokens)),
                    locale: locale
                ),
                systemImage: "doc.text"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            compactionRule
        }
        .accessibilityHint(Text(AppStrings.Assistant.compactionExplanation))
    }

    private var compactionRule: some View {
        Color(uiColor: .separator)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func compactionActivityRow(_ activity: AgentCompactionActivity) -> some View {
        switch activity.state {
        case .running:
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                Text(AppStrings.Assistant.compactingContext).modifier(MobileAssistantScanning(active: true))
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed(let reason):
            DisclosureGroup(isExpanded: disclosureBinding(for: .compactionActivity(activity.id))) {
                HStack(alignment: .top, spacing: 12) {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 1)
                        .accessibilityHidden(true)
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 24)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(AppStrings.Assistant.compactionFailed)
                        .foregroundStyle(.primary)
                }
                .font(.callout)
            }
            .tint(.secondary)
            .accessibilityHint(Text(AppStrings.Assistant.showFailureDetails))
        }
    }

    private func agentFailureRow(_ failure: AgentRunFailureNotice) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(for: .failure(failure.id))) {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(width: 1)
                    .accessibilityHidden(true)
                Text(failure.reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AssistantCopyButton(text: failure.reason) {
                    UIPasteboard.general.string = $0
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 24)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(AppStrings.Assistant.agentError)
                    .foregroundStyle(.primary)
            }
            .font(.callout)
        }
        .tint(.secondary)
        .accessibilityHint(Text(AppStrings.Assistant.showFailureDetails))
    }

    private var imageTileSize: CGFloat { sizeClass == .compact ? 104 : 160 }

    private func messageRow(_ message: ChatMessage, canEdit: Bool, canFork: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.images.isEmpty {
                MobileAssistantImageFlowLayout(
                    alignment: message.role == .user ? .trailing : .leading
                ) {
                    ForEach(message.images) { image in
                        Button {
                            open(data: image.data, name: image.label)
                        } label: {
                            if let uiImage = UIImage(data: image.data) {
                                Image(uiImage: uiImage).resizable().scaledToFill()
                                    .frame(width: imageTileSize, height: imageTileSize)
                                    .clipShape(.rect(cornerRadius: 12))
                                    .accessibilityLabel(image.label)
                            } else {
                                Label(image.label, systemImage: "photo")
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: message.role == .user ? .trailing : .leading
                )
            }
            ForEach(message.contextChips) { chip in
                HStack {
                    if message.role == .user { Spacer(minLength: 0) }
                    Button {
                        if let attachment = chip.attachment {
                            open(data: attachment.data, name: attachment.suggestedFilename)
                        } else if let image = message.images.first(where: { $0.id == chip.id || $0.label == chip.label }
                        ) {
                            open(data: image.data, name: image.label)
                        }
                    } label: {
                        Label(chip.label, systemImage: chip.kind.symbol)
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 6)
                            .background(.quaternary, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(
                        chip.attachment == nil
                            && !message.images.contains { $0.id == chip.id || $0.label == chip.label })
                    if message.role != .user { Spacer(minLength: 0) }
                }
            }
            if !message.text.isEmpty {
                if message.role == .user {
                    HStack {
                        Spacer(minLength: 44)
                        MobileAssistantUserBubble(text: message.text)
                    }
                } else {
                    MobileAssistantMarkdown(text: message.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if message.isStreaming && message.text.isEmpty && message.reasoning.isEmpty {
                MobileAssistantActivity(
                    cyclesText: message.retryProgress == nil,
                    reconnectingTitle: message.retryProgress.map {
                        AgentWorkPresentation.reconnectingTitle($0, locale: locale)
                    }
                )
            }
            if !message.isStreaming { messageActions(message, canEdit: canEdit, canFork: canFork) }
            ForEach(message.commands) { command in MobileAssistantCommandRow(command: command) }
        }
        .contextMenu {
            Button(AppStrings.Common.copy.swiftUIKey, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
            ShareLink(item: message.text)
            if message.origin == nil {
                if canEdit {
                    Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
                        editedText = message.text
                        editing = message
                    }
                }
                if canFork {
                    Button(AppStrings.Assistant.forkConversation.swiftUIKey, systemImage: "arrow.triangle.branch") {
                        Task { await model.fork(conversation, at: message.id) }
                    }
                }
            }
        }
    }

    private func messageActions(_ message: ChatMessage, canEdit: Bool, canFork: Bool) -> some View {
        HStack(spacing: 4) {
            if message.role == .user {
                Spacer(minLength: 0)
                timestamp(message)
            }

            if canEdit {
                messageAction(AppStrings.Common.edit, systemImage: "pencil") {
                    editedText = message.text
                    editing = message
                }
            }

            AssistantCopyButton(text: message.text, minimumLabelSize: 44) {
                UIPasteboard.general.string = $0
            }
            .font(.caption)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if let origin = message.origin {
                let presentation = MobileAssistantAgentOriginPresentation(
                    origin: origin,
                    source: model.library.conversation(id: origin.sourceConversationID),
                    locale: locale)
                MobileAssistantAgentOriginButton(presentation: presentation) {
                    guard let target = model.library.conversation(id: origin.sourceConversationID) else { return }
                    model.select(target)
                }
            }

            if canFork {
                messageAction(AppStrings.Assistant.fork, systemImage: "arrow.triangle.branch") {
                    Task { await model.fork(conversation, at: message.id) }
                }
            }

            if message.role != .user {
                timestamp(message)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func messageAction(
        _ title: LocalizedStringResource,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func timestamp(_ message: ChatMessage) -> some View {
        Text(ChatMessageTimestampFormatter.string(for: message.createdAt, locale: locale))
            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
    }

    private func hostName(_ id: UUID) -> String {
        app.library.host(id)?.name ?? String(id.uuidString.prefix(8))
    }

    private func toolRow(_ card: AgentToolCard) -> some View {
        MobileAssistantToolRow(card: card, presentation: presentation, hostName: hostName)
    }

    private func disclosureBinding(for id: AssistantTranscriptDisclosureID) -> Binding<Bool> {
        Binding(
            get: { presentation.isExpanded(id) },
            set: { expanded in
                if expanded != presentation.isExpanded(id) { presentation.toggleDisclosure(id) }
            }
        )
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
