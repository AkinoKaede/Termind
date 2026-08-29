import SwiftUI

/// A conversation rendered as chips + transcript + composer.
///
/// Shared by the session Assistant sidebar and full Assistant destination so the two can never drift; only
/// the padding and the provider header differ.
struct ConversationView: View {
    enum Region {
        case all
        case transcript
        case interaction
    }

    let conversation: ConversationModel
    var isCompact: Bool = false
    var region: Region = .all
    /// Forwarded to the composer. Only the sidebar has a focused pane to
    /// describe, so only the sidebar passes one.
    var sessionContext: SessionContext = .none
    /// A conversation can be shown on both surfaces. Terminal actions belong
    /// to the Workspace sidebar displaying it, not to the conversation itself.
    var showsTerminalActions = false
    /// Surface-owned navigation. `nil` means this composer already is the new
    /// chat surface, so offering New chat there would be a circular action.
    var onNewChat: (() -> Void)?
    /// Used by a scratch New Chat surface that must be promoted into history
    /// before the app starts its first run.
    var onSend: (() -> Void)?

    @Environment(WindowModel.self) private var window
    @State private var transcriptPresentation = TranscriptPresentationState()

    var body: some View {
        switch region {
        case .all:
            VStack(spacing: 0) {
                transcript
                interactionSurface
            }
        case .transcript:
            transcript
        case .interaction:
            interactionSurface
        }
    }

    @ViewBuilder
    private var interactionSurface: some View {
        if conversation.isArchived {
            archivedSurface
        } else if let interaction = conversation.pendingUserInteraction {
            blockingSurface { userInteraction(interaction) }
        } else if let approval = conversation.pendingApproval {
            blockingSurface {
                AgentApprovalCard(request: approval, conversation: conversation)
            }
        } else {
            if !conversation.tasks.isEmpty {
                chatColumn {
                    AgentTaskCapsuleView(
                        conversation: conversation, isCompact: isCompact
                    )
                }
                // Below the composer's Slash overlay, above Steering and
                // every ordinary surface in this interaction region.
                .zIndex(50)
            }
            if !conversation.pendingSteering.isEmpty {
                chatColumn {
                    SteeringQueueView(
                        conversation: conversation,
                        isCompact: isCompact,
                        isEmbedded: true,
                        surfaceStyle: interactionSurfaceStyle
                    )
                }
            }
            ComposerView(
                conversation: conversation,
                surfaceStyle: interactionSurfaceStyle,
                maxContentWidth: isCompact ? nil : Metrics.Chat.contentMaxWidth,
                sessionContext: sessionContext,
                includesTerminalSuggestion: showsTerminalActions,
                onNewChat: onNewChat,
                onSend: onSend
            )
            .zIndex(100)
        }
    }

    @ViewBuilder
    private var archivedSurface: some View {
        if isCompact {
            archivedSurfaceContent
                .composerBlock(style: interactionSurfaceStyle)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.top, Metrics.Space.s)
                .padding(.bottom, Metrics.Space.s)
        } else {
            archivedSurfaceContent
                .padding(Metrics.Space.l)
                .termindGlassBar()
        }
    }

    private var archivedSurfaceContent: some View {
        HStack(spacing: Metrics.Space.m) {
            Label("Archived conversations are read-only.", systemImage: "archivebox")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unarchive") {
                window.setAssistantArchived(conversation.id, archived: false)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var interactionSurfaceStyle: AssistantInteractionSurfaceStyle {
        isCompact ? .sidebar : .standard
    }

    private func chatColumn<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, Metrics.Space.l)
            .frame(maxWidth: isCompact ? .infinity : Metrics.Chat.contentMaxWidth)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func userInteraction(_ interaction: ConversationModel.PendingUserInteraction)
        -> some View
    {
        switch interaction {
        case .questions(let input):
            AgentUserInputCard(
                request: input, conversation: conversation, isCompact: isCompact
            )
        case .sshAuthentication(let authentication):
            AgentSSHAuthenticationCard(
                request: authentication, conversation: conversation
            )
        case .sshHostKey(let request):
            AgentSSHHostKeyCard(request: request, conversation: conversation)
        }
    }

    private func blockingSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(
                minHeight: max(
                    0,
                    (isCompact
                        ? Metrics.Chat.compactComposerSurfaceMinHeight
                        : Metrics.Chat.composerSurfaceMinHeight) - Metrics.Space.xxl
                ),
                alignment: .top
            )
            .composerBlock(style: interactionSurfaceStyle)
            .padding(.horizontal, Metrics.Space.l)
            .frame(maxWidth: isCompact ? .infinity : Metrics.Chat.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, Metrics.Space.s)
            .padding(.bottom, isCompact ? Metrics.Space.s : Metrics.Space.l)
            .zIndex(50)
    }

    private var transcript: some View {
        ConversationTranscriptSurface(
            conversation: conversation,
            isCompact: isCompact,
            sessionContext: sessionContext,
            showsTerminalActions: showsTerminalActions,
            presentation: transcriptPresentation
        )
    }

}

/// Keeps composer draft edits outside the transcript's observation boundary.
///
/// `ConversationView` owns both surfaces, but a draft keystroke must not rebuild
/// the timeline, hash every Markdown entry, or ask ListViewKit to compare a long
/// conversation. This child observes only transcript-affecting properties; the
/// composer remains free to update at key-repeat speed.
private struct ConversationTranscriptSurface: View {
    let conversation: ConversationModel
    let isCompact: Bool
    let sessionContext: SessionContext
    let showsTerminalActions: Bool
    let presentation: TranscriptPresentationState

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let timeline = conversation.timeline
        let entries = TranscriptEntry.items(
            timeline: timeline,
            isInterrupted: conversation.runState == .interrupted,
            canEdit: conversation.canEditUserMessage,
            canFork: conversation.canForkAssistantMessage
        )
        return TranscriptListView(
            entries: entries,
            latestUserMessageID: conversation.messages.last(where: { $0.role == .user })?.id,
            configuration: .init(
                isCompact: isCompact,
                showsTerminalActions: showsTerminalActions,
                isConversationStreaming: conversation.isStreaming,
                locale: locale,
                reduceMotion: reduceMotion
            ),
            actions: .init(
                hostName: { id in
                    app.hostLibrary.host(id)?.name ?? String(id.uuidString.prefix(8))
                },
                editUserMessage: { id, text in
                    window.editAssistantUserMessage(
                        conversation.id,
                        messageID: id,
                        text: text,
                        context: sessionContext,
                        includesTerminalSuggestion: showsTerminalActions
                    )
                },
                forkAssistantMessage: { id in
                    window.forkAssistantConversation(
                        conversation.id,
                        at: id,
                        inSidebar: isCompact
                    )
                },
                resolvePlan: { id, outcome in
                    conversation.resolvePlan(id, as: outcome)
                },
                implementPlan: { card in
                    guard app.proAccess.require(.assistant) else { return }
                    conversation.resolvePlan(card.id, as: .implemented)
                    let prompt = ConversationModel.implementationPrompt(for: card.plan)
                    conversation.appendUserTurn(prompt)
                    app.startAgentRun(conversation, prompt: prompt)
                },
                canDeliverCommand: {
                    guard let workspace = window.selectedWorkspace else { return false }
                    return workspace.focusedPane.sshSession != nil
                        || !workspace.broadcastTargets.isEmpty
                },
                deliverCommand: { command, submit in
                    guard let workspace = window.selectedWorkspace,
                        let origin = workspace.focusedPane.sshSession
                            ?? workspace.broadcastTargets.first
                    else { return }
                    workspace.deliver(command, from: origin, submit: submit)
                }
            ), presentation: presentation
        )
    }
}

// MARK: - Tool calls

/// One disclosure for a run's process. Live and exceptional work opens by
/// default on both Assistant surfaces; each surface retains independent reader
/// overrides after that.
private struct AgentWorkGroupView: View {
    let group: AgentWorkGroup
    let isCompact: Bool
    let presentation: TranscriptPresentationState
    let onDisclosureToggle: () -> Void

    @Environment(\.locale) private var locale

    private var defaultExpanded: Bool {
        AgentWorkPresentation.isExpandedByDefault(
            for: group.run.state, appearsAfterAnswer: group.appearsAfterAnswer,
            isCompact: isCompact
        )
    }

    private var isExpanded: Bool {
        presentation.isExpanded(group.id, default: defaultExpanded)
    }

    /// One disclosure for both lives of a run, not one per state. Branching the
    /// whole disclosure on `isTerminal` changed its structural identity, so the
    /// moment a run finished SwiftUI tore the entire process subtree down and
    /// rebuilt it — discarding every tool row the reader had open — in the same
    /// frame as the largest content shrink of the run. Only the header's clock
    /// differs, so only the header branches.
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Button {
                onDisclosureToggle()
                presentation.toggleDisclosure(group.id, default: defaultExpanded)
            } label: {
                header
            }
            .buttonStyle(.plain)
            .help(
                Text(
                    isExpanded ? String(localized: "Hide work") : String(localized: "Show work")
                )
            )
            .accessibilityLabel(Text(title(at: group.run.finishedAt ?? .now)))
            .accessibilityValue(
                Text(
                    isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
                )
            )
            .accessibilityHint(
                Text(
                    isExpanded
                        ? String(localized: "Collapse work process")
                        : String(localized: "Expand work process")
                ))

            if isExpanded { workItems }
            Divider()
        }
        .onChange(of: group.run.state) { _, state in
            // Runtime transitions are authoritative only until the reader says
            // otherwise. Someone who opened this process to watch it did not
            // ask for it to close the instant the run reported success.
            presentation.followDefault(
                AgentWorkPresentation.isExpandedByDefault(
                    for: state, appearsAfterAnswer: group.appearsAfterAnswer,
                    isCompact: isCompact
                ),
                for: group.id
            )
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var header: some View {
        if group.run.state.isTerminal {
            headerRow(at: group.run.finishedAt ?? .now)
        } else {
            // Anchored to the run's own start rather than `.now`, which is
            // re-read on every body evaluation — many times a second while a
            // reply streams — and re-seeds the tick phase each time.
            TimelineView(.periodic(from: group.run.startedAt, by: 1)) { context in
                headerRow(at: context.date)
            }
        }
    }

    private func headerRow(at date: Date) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Text(title(at: date))
                .font(MarkdownTypography.body)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    /// Plain, like every stack in the transcript column. See the note on the
    /// column itself: nothing here may report an estimated height, because a
    /// collapse is exactly what makes such an estimate wrong and unrecoverable.
    /// A group holds tens of rows and only exists while it is open, so laziness
    /// bought nothing to weigh against that.
    private var workItems: some View {
        VStack(alignment: .leading, spacing: Metrics.Chat.blockSpacing) {
            ForEach(group.items) { item in
                switch item {
                case .reasoning(let block):
                    reasoningBlock(
                        block,
                        isActive: group.activeReasoningBlockID == block.id
                    )
                case .message(let message):
                    processMessage(message)
                case .tool(let card):
                    AgentToolRowView(
                        card: card, presentation: presentation,
                        onDisclosureToggle: onDisclosureToggle
                    )
                case .tools(let batch):
                    AgentToolBatchView(
                        batch: batch, presentation: presentation,
                        onDisclosureToggle: onDisclosureToggle
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reasoning uses MarkdownView's streaming path but never gains terminal
    /// actions; it is narration, not a suggested command.
    private func reasoningBlock(
        _ block: AgentReasoningBlock, isActive: Bool
    ) -> some View {
        TermindMarkdownView(
            text: block.text, isStreaming: isActive,
            isAssistant: false, isCompact: isCompact,
            tone: .secondary
        )
        .modifier(ScanningTextMask(isActive: isActive))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func processMessage(_ message: ChatMessage) -> some View {
        if message.text.isEmpty {
            if message.isStreaming {
                WorkingIndicator()
            }
        } else {
            TermindMarkdownView(
                text: message.text, isStreaming: message.isStreaming,
                isAssistant: true, isCompact: isCompact
            )
            .textSelection(.enabled)
        }
    }

    private func title(at now: Date) -> String {
        let end = group.run.finishedAt ?? now
        return AgentWorkPresentation.title(
            for: group.run.state, from: group.run.startedAt, to: end, locale: locale
        )
    }
}

/// Two or more contiguous calls inside Worked. While any call is unfinished,
/// the header reuses those calls' ordinary live wording exactly; only a fully
/// terminal batch changes over to a compact action summary.
private struct AgentToolBatchView: View {
    let batch: AgentToolBatch
    let presentation: TranscriptPresentationState
    let onDisclosureToggle: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    private var isExpanded: Bool { presentation.isExpanded(batch.id) }

    private var cards: [AgentToolCard] { batch.cards }

    private var unfinished: [AgentToolCard] {
        cards.filter { card in
            switch card.state {
            case .proposed, .waitingForApproval, .waitingForUser, .reviewing, .running: true
            case .completed, .denied, .failed, .interrupted: false
            }
        }
    }

    private var displayedReasoning: String? {
        guard !unfinished.isEmpty, let reasoning = batch.reasoning else { return nil }
        return AgentToolPresentation.reasoningTitle(from: reasoning.markdown)
    }

    private var title: String {
        guard !unfinished.isEmpty else {
            return AgentToolPresentation.batchSummary(for: cards, locale: locale)
        }
        if let displayedReasoning { return displayedReasoning }
        return unfinished.map { card in
            AgentToolPresentation.summary(
                for: card, hostName: hostName(for: card), locale: locale
            )
        }.joined(separator: "; ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Button {
                onDisclosureToggle()
                presentation.toggleDisclosure(batch.id)
            } label: {
                HStack(spacing: Metrics.Space.s) {
                    Image(systemName: AgentToolPresentation.batchSymbol(for: cards))
                        .foregroundStyle(iconTint)
                        .frame(width: Metrics.Sidebar.rowIcon)
                    Text(title)
                        .font(MarkdownTypography.body)
                        .lineLimit(displayedReasoning == nil ? nil : 1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .modifier(ScanningTextMask(isActive: !unfinished.isEmpty))
                        .layoutPriority(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(
                Text(
                    isExpanded ? String(localized: "Hide tools") : String(localized: "Show tools")
                )
            )
            .accessibilityLabel(Text(title))
            .accessibilityValue(
                Text(
                    isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
                ))

            if isExpanded {
                // Plain, for the same reason `AgentWorkGroupView.workItems` is.
                VStack(alignment: .leading, spacing: Metrics.Chat.blockSpacing) {
                    ForEach(cards) { card in
                        AgentToolRowView(
                            card: card, showsActivityAnimation: false,
                            presentation: presentation,
                            onDisclosureToggle: onDisclosureToggle
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func hostName(for card: AgentToolCard) -> String? {
        guard let id = card.invocation.targetHostID else { return nil }
        return app.hostLibrary.host(id)?.name ?? String(id.uuidString.prefix(8))
    }

    private var iconTint: Color {
        switch AgentToolPresentation.batchTint(for: cards) {
        case .secondary: .secondary
        case .warning: .orange
        case .success: .green
        case .failure: .red
        }
    }
}

/// One tool call, as a line the reader can open.
///
/// A filled card per call turns a reply that used four tools into four grey
/// slabs around one paragraph of prose. The one-line action is what people scan
/// for; only the review result and output appear when they ask for more.
private struct AgentToolRowView: View {
    let card: AgentToolCard
    var showsActivityAnimation = true
    let presentation: TranscriptPresentationState
    let onDisclosureToggle: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    private var isExpanded: Bool { presentation.isExpanded(card.id) }

    private var summary: String {
        AgentToolPresentation.summary(for: card, hostName: hostName, locale: locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Button {
                onDisclosureToggle()
                presentation.toggleDisclosure(card.id)
            } label: {
                HStack(spacing: Metrics.Space.s) {
                    Image(systemName: AgentToolPresentation.symbol(for: card))
                        .foregroundStyle(tint)
                        .frame(width: Metrics.Sidebar.rowIcon)
                    Text(summary)
                        .font(MarkdownTypography.body)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .foregroundStyle(card.state == .running ? .secondary : .primary)
                        .modifier(
                            ScanningTextMask(
                                isActive: showsActivityAnimation && card.state == .running
                            )
                        )
                        .layoutPriority(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if card.state == .reviewing {
                        Image(systemName: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text("Security Review in progress"))
                    }
                }
                .opacity(card.state == .interrupted ? 0.5 : 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(
                Text(
                    isExpanded
                        ? String(localized: "Hide details") : String(localized: "Show details")
                ))

            if isExpanded { detail }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if let review = card.review {
                Label(
                    "Security Review: \(review.risk.displayName) — \(review.reason)",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            if let result = card.result {
                if let detail = AgentToolPresentation.detail(for: card, locale: locale) {
                    AgentToolDetailView(detail: detail, isError: result.isError)
                }

                if result.isTruncated {
                    Text("Output truncated")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Metrics.Sidebar.rowIcon)
    }

    private var hostName: String? {
        guard let id = card.invocation.targetHostID else { return nil }
        return app.hostLibrary.host(id)?.name ?? String(id.uuidString.prefix(8))
    }

    private var tint: Color {
        switch card.state {
        case .denied, .failed: .red
        case .interrupted: .secondary
        case .reviewing, .waitingForApproval, .waitingForUser: .orange
        case .completed: .green
        default: .secondary
        }
    }
}

/// Structured, deliberately low-chrome tool output. Protocol keys never reach
/// this view: labels, sections and text styles have already been chosen by the
/// presentation projection, leaving SwiftUI responsible only for hierarchy.
private struct AgentToolDetailView: View {
    let detail: AgentToolDetail
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            ForEach(Array(detail.items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .field(let field):
                    fieldView(field)
                case .message(let message, let tint):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(color(tint))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .text(let block):
                    textBlock(block)
                case .list(let list):
                    listBlock(list)
                case .groupedList(let list):
                    groupedList(list)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldView(_ field: AgentToolDetail.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
            Text(field.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 76, alignment: .leading)
            if let rawURL = field.url, let url = URL(string: rawURL) {
                Link(field.value, destination: url)
                    .font(field.isMonospaced ? .caption.monospaced() : .caption)
            } else {
                Text(field.value)
                    .font(field.isMonospaced ? .caption.monospaced() : .caption)
                    .foregroundStyle(isError ? .red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func textBlock(_ block: AgentToolDetail.TextBlock) -> some View {
        if let title = block.title {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        let preview = AgentToolPresentation.preview(block.text)
        Text(preview.displayed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(block.style == .monospaced ? .caption.monospaced() : .caption)
            .foregroundStyle(isError ? .red : .secondary)
            .textSelection(.enabled)

        if preview.isShortened {
            HStack(spacing: Metrics.Space.s) {
                Text("Output shortened for display")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                CopyButton(text: preview.full, title: "Copy Full Output")
            }
        }
    }

    @ViewBuilder
    private func listBlock(_ list: AgentToolDetail.ListBlock) -> some View {
        if let title = list.title {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        if list.rows.isEmpty, let empty = list.emptyMessage {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                ForEach(Array(list.rows.enumerated()), id: \.offset) { _, row in
                    detailRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func groupedList(_ list: AgentToolDetail.GroupedList) -> some View {
        Text(list.summary)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        if list.isScrollable {
            ScrollView {
                groupedListContents(list)
            }
            .frame(maxHeight: 360)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            groupedListContents(list)
        }
    }

    /// Plain rather than lazy: when the list is short enough not to need its own
    /// `ScrollView`, this renders straight into the transcript column, which is
    /// non-lazy throughout so that no row ever reports an estimated height.
    private func groupedListContents(
        _ list: AgentToolDetail.GroupedList
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            ForEach(Array(list.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        detailRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ row: AgentToolDetail.ListRow) -> some View {
        HStack(alignment: .top, spacing: Metrics.Space.s) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(color(row.tint))
                    .frame(width: Metrics.Sidebar.rowIcon)
            }
            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                if let rawURL = row.url, let url = URL(string: rawURL) {
                    Link(row.title, destination: url)
                        .font(.caption.weight(.medium))
                } else {
                    Text(row.title).font(.caption.weight(.medium))
                }
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !row.badges.isEmpty {
                    FlowLayout(spacing: Metrics.Space.xs, fillsWidth: false) {
                        ForEach(Array(row.badges.enumerated()), id: \.offset) { _, badge in
                            CardChip(text: badge)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ tint: AgentToolDetail.Tint) -> Color {
        switch tint {
        case .secondary: .secondary
        case .warning: .orange
        case .success: .green
        case .failure: .red
        }
    }
}

// MARK: - Compaction

private struct AgentCompactionActivityRowView: View {
    let activity: AgentCompactionActivity
    let presentation: TranscriptPresentationState
    let onDisclosureToggle: () -> Void

    private var isExpanded: Bool { presentation.isExpanded(activity.id) }

    private var failure: String? {
        guard case .failed(let reason) = activity.state else { return nil }
        return reason
    }

    private var statusTitle: String {
        failure == nil
            ? String(localized: "Compacting context")
            : String(localized: "Couldn’t compact context")
    }

    private var helpTitle: String {
        failure == nil
            ? String(localized: "Compacting context")
            : String(localized: "Show failure details")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Button {
                guard failure != nil else { return }
                onDisclosureToggle()
                presentation.toggleDisclosure(activity.id)
            } label: {
                HStack(spacing: Metrics.Space.s) {
                    if failure == nil {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(.secondary)
                            .frame(width: Metrics.Sidebar.rowIcon)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .frame(width: Metrics.Sidebar.rowIcon)
                    }

                    Text(statusTitle)
                        .font(MarkdownTypography.body)
                        .foregroundStyle(failure == nil ? .secondary : .primary)
                        .modifier(ScanningTextMask(isActive: failure == nil))

                    Spacer(minLength: Metrics.Space.s)
                    if failure != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(helpTitle))

            if isExpanded, let failure {
                HStack(alignment: .top, spacing: Metrics.Space.m) {
                    RoundedRectangle(cornerRadius: Metrics.Chat.rule / 2)
                        .fill(.quaternary)
                        .frame(width: Metrics.Chat.rule)
                    Text(failure)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .padding(.leading, Metrics.Sidebar.rowIcon)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Where the model's memory of this conversation now begins.
///
/// A rule with a label rather than a card, because it marks a boundary rather
/// than reporting an event. Everything above it is still here to scroll through
/// — compaction changes what is *sent*, never what is kept — and this says so
/// plainly enough that nobody has to wonder where their history went.
private struct AgentCompactionRowView: View {
    let mark: AgentCompactionMark

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            line
            Label {
                Text(
                    "Compacted — \(ContextBreakdownView.compact(mark.summarizedTokens)) summarized to \(ContextBreakdownView.compact(mark.keptTokens))"
                )
            } icon: {
                Image(systemName: "doc.text")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            line
        }
        .help(Text("Earlier turns are summarized for the model. Nothing was deleted."))
    }

    private var line: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
    }
}

// MARK: - Tasks

/// What the agent is working through, as one small capsule.
///
/// Above the composer rather than in the transcript, and that difference is the
/// design. A plan is a document decided once, so it belongs where it happened. A
/// task list is live state rewritten every turn: one transcript row that
/// silently mutated would misdate itself, and one row per revision would bury
/// the conversation it describes.
///
/// A capsule rather than a strip because at rest the only thing worth saying is
/// "4 / 9". It sits above every other thing stacked over the composer — the
/// approval card, a question, the steering queue — because it is the *state* of
/// the work, and those are all interruptions to it.
///
/// The list opens on hover, as an overlay drawn upward over the transcript.
/// Inserting it into the stack instead would push the conversation every time
/// the pointer crossed the pill.
struct AgentTaskCapsuleView: View {
    let conversation: ConversationModel
    var isCompact = false

    /// Two hover flags, not one. The list is an overlay outside the capsule's
    /// own frame, so hovering it does not keep the capsule's `onHover` true —
    /// and with one flag the list would vanish the moment the pointer reached
    /// for it.
    @State private var isHoveringCapsule = false
    @State private var isHoveringList = false
    @State private var isPinned = false
    /// The rows' own height. A `ScrollView` reports none — left alone it takes
    /// every point it is offered.
    @State private var rowsHeight: CGFloat = 0
    @State private var overlayHeight: CGFloat = 0

    private var isComplete: Bool {
        conversation.completedTaskCount == conversation.tasks.count
    }

    private var isExpanded: Bool { isPinned || isHoveringCapsule || isHoveringList }

    var body: some View {
        capsule
            .overlay(alignment: .top) {
                if isExpanded {
                    VStack(spacing: 0) {
                        list
                        // Keeps hover continuous while leaving a small visual
                        // gap between the floating list and its capsule.
                        Color.clear.frame(height: Metrics.Space.xs)
                    }
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        overlayHeight = $0
                    }
                    // The overlay's bottom meets the capsule's top. Using
                    // `.top` is important: bottom-aligning first and then
                    // subtracting the list height moved it upward twice.
                    .offset(y: -overlayHeight)
                    .onHover { isHoveringList = $0 }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Metrics.Space.s)
            .animation(.easeOut(duration: 0.12), value: isExpanded)
    }

    private var capsule: some View {
        Button {
            // Hover is not available to everyone, and a pinned list is also how
            // you read one without holding the pointer still.
            isPinned.toggle()
        } label: {
            HStack(spacing: Metrics.Space.xs) {
                ProgressRing(
                    share: Double(conversation.completedTaskCount)
                        / Double(max(conversation.tasks.count, 1)),
                    tint: isComplete ? .green : .accentColor,
                    diameter: 10, lineWidth: 1.7
                )
                Text("Step \(conversation.completedTaskCount) / \(conversation.tasks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, 3)
            .termindGlassCapsule(isInteractive: true)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringCapsule = $0 }
        .help(Text("\(conversation.completedTaskCount) of \(conversation.tasks.count) tasks done"))
        .accessibilityLabel(
            Text("Tasks, \(conversation.completedTaskCount) of \(conversation.tasks.count) done")
        )
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                ForEach(conversation.tasks) { task in
                    row(task)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                rowsHeight = $0
            }
        }
        .frame(height: min(rowsHeight, Metrics.Chat.taskListMaxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .padding(Metrics.Space.l)
        .frame(
            width: isCompact
                ? Metrics.Chat.compactTaskListWidth : Metrics.Chat.taskListWidth
        )
        .termindGlassSurface(cornerRadius: Metrics.Chat.composerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tasks"))
    }

    private func row(_ task: AgentTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
            Image(systemName: symbol(task.status))
                .font(.caption)
                .foregroundStyle(tint(task.status))
                .frame(width: Metrics.Sidebar.rowIcon)
            Text(task.title)
                .font(.callout)
                .foregroundStyle(task.status == .completed ? .secondary : .primary)
                .strikethrough(task.status == .completed, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(_ status: AgentTask.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func tint(_ status: AgentTask.Status) -> Color {
        switch status {
        case .pending: .secondary
        case .inProgress: .accentColor
        case .completed: .green
        }
    }
}

// MARK: - Plans

/// A finished plan, as a row the reader can open.
///
/// In the transcript rather than stacked above the composer, because nothing is
/// suspended on it: the run that wrote it has already ended. It is part of what
/// happened, in the order it happened, and it stays readable after it has been
/// answered — which the panel treatment, dismissed on the first click, would not
/// allow.
private struct AgentPlanRowView: View {
    let card: AgentPlanCard
    let conversation: ConversationModel
    let presentation: TranscriptPresentationState
    let onDisclosureToggle: () -> Void

    @Environment(AppModel.self) private var app
    /// Collapsed until the reader opens it. A plan is long by construction, and
    /// one that unfurled on arrival would push the conversation it belongs to
    /// off the screen at the moment the reader wants to see both.
    private var isExpanded: Bool { presentation.isExpanded(card.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            header
            // Shown either way. Collapsing to a bare title would make the row a
            // thing to be opened before it says anything, and the first lines of
            // a plan are usually its goal — enough to decide whether the rest is
            // worth reading.
            planBody
            if card.outcome == .pending {
                actions
            }
        }
        .padding(Metrics.Space.l)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: Metrics.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    /// The plan, whole or as much of it as fits.
    ///
    /// Capped by height rather than by a block count, because a block is not a
    /// unit of reading: one paragraph can be four lines and the next one word.
    /// The gradient is the honest part — a hard clip looks like the plan simply
    /// ends there, while a fade says there is more and the chevron opens it.
    @ViewBuilder
    private var planBody: some View {
        let rendered = TermindMarkdownView(
            text: card.plan.body,
            isAssistant: true,
            isCompact: true
        )
        .padding(.leading, Metrics.Sidebar.rowIcon + Metrics.Space.s)

        if isExpanded {
            rendered
        } else {
            // The preview opens the plan too. Fading the last line into nothing
            // is a promise that there is more, and answering it by hunting for
            // an 8pt chevron would be a poor return on having read that far.
            Button {
                onDisclosureToggle()
                if !isExpanded { presentation.toggleDisclosure(card.id) }
            } label: {
                rendered
                    .frame(maxHeight: Metrics.Chat.planPreviewHeight, alignment: .top)
                    .clipped()
                    .mask(alignment: .top) {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.72),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The header says the same thing to VoiceOver, and a faded
            // duplicate of text that is about to be read in full is noise.
            .accessibilityHidden(true)
        }
    }

    private var header: some View {
        Button {
            onDisclosureToggle()
            presentation.toggleDisclosure(card.id)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: Metrics.Sidebar.rowIcon)
                Text(card.plan.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(isExpanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: Metrics.Space.s)
                if let outcome = outcomeLabel {
                    Text(outcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(
            Text(
                isExpanded
                    ? String(localized: "Hide the plan") : String(localized: "Show the plan")
            ))
    }

    private var actions: some View {
        HStack(spacing: Metrics.Space.m) {
            Button("Discard", role: .destructive) {
                conversation.resolvePlan(card.id, as: .discarded)
            }
            Spacer(minLength: 0)
            // No button, deliberately. "Keep planning" is just typing the next
            // message — the mode is still on and the composer is right there —
            // and a button that only moves focus teaches nothing.
            Text("Reply to keep planning")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Implement") { implement() }
                .buttonStyle(.borderedProminent)
                .disabled(conversation.isStreaming)
        }
    }

    /// Leaves plan mode and starts the run that acts on it.
    ///
    /// A new run rather than resuming a suspended one: the plan was read by a
    /// person on their own time, and a run held open across that would have kept
    /// an SSH pool and a provider connection alive while nobody was there.
    private func implement() {
        guard app.proAccess.require(.assistant) else { return }
        conversation.resolvePlan(card.id, as: .implemented)
        let prompt = ConversationModel.implementationPrompt(for: card.plan)
        conversation.appendUserTurn(prompt)
        app.startAgentRun(conversation, prompt: prompt)
    }

    private var symbol: String {
        switch card.outcome {
        // The same lit bulb the chip and the `/plan` row carry, so a plan is
        // recognisable as one thing wherever it turns up. Once decided, the
        // outcome is the more useful glyph.
        case .pending: "lightbulb.max"
        case .implemented: "checkmark.circle.fill"
        case .discarded: "xmark.circle"
        }
    }

    private var tint: Color {
        switch card.outcome {
        case .pending: .accentColor
        case .implemented: .green
        case .discarded: .secondary
        }
    }

    private var outcomeLabel: LocalizedStringKey? {
        switch card.outcome {
        case .pending: nil
        case .implemented: "Implemented"
        case .discarded: "Discarded"
        }
    }
}

// MARK: - Decisions

/// Kept as an emphasised card on purpose. This is the one place in the
/// transcript that is waiting on a person, and the de-emphasis the rest of this
/// view got would make it read like history.
private struct AgentApprovalCard: View {
    let request: AgentApprovalRequest
    let conversation: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack {
                Label("Approval required", systemImage: "hand.raised.fill").font(.headline)
                Spacer()
                QueueDepthLabel(remaining: conversation.pendingApprovals.count)
            }
            Text(request.descriptor.qualifiedName).font(.callout.weight(.semibold))
            if let host = request.invocation.targetHostID {
                Text("Host: \(host.uuidString)").font(.caption).foregroundStyle(.secondary)
            }
            Text(AgentSensitiveDataRedactor.redactedJSON(request.invocation.call.arguments).encodedString)
                .font(.caption.monospaced()).textSelection(.enabled)
            ForEach(request.localReasons, id: \.self) {
                Text($0).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Deny", role: .destructive) { conversation.respondToApproval(allow: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow Once") { conversation.respondToApproval(allow: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .activeFormKeyboardActions(
            isDefaultEnabled: true,
            onDefault: { conversation.respondToApproval(allow: true) },
            onCancel: { conversation.respondToApproval(allow: false) }
        )
    }
}

/// How much else is waiting behind this card.
///
/// A parallel turn can raise several questions, and they are answered one at a
/// time. Without this, dismissing one card and finding another in its place
/// reads as the same card having failed to go away.
private struct QueueDepthLabel: View {
    let remaining: Int

    var body: some View {
        if remaining > 1 {
            Text("1 of \(remaining)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// SSH authentication presented in the Agent surface. Agent owns placement and
/// queue state; the actual credential form is shared with the Journey.
private struct AgentSSHAuthenticationCard: View {
    let request: AgentSSHAuthenticationRequest
    let conversation: ConversationModel

    private var requiresPassphrase: Bool {
        if case .passphrase = request.mode { return true }
        return false
    }

    private var prompt: SSHAuthenticationPrompt {
        SSHAuthenticationPrompt(
            host: Host(
                id: request.hostID, name: request.displayName,
                host: request.address
            ),
            selectedIdentityID: request.selectedIdentityID,
            username: request.username,
            selectedKeyID: request.selectedKeyID,
            failureMessage: request.failureMessage,
            requiresPassphrase: requiresPassphrase,
            mode: request.failureMessage == nil ? .localIdentity : .serverChallenge
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if conversation.pendingSSHAuthentications.count > 1 {
                HStack {
                    Spacer()
                    QueueDepthLabel(
                        remaining: conversation.pendingSSHAuthentications.count
                    )
                }
                .padding(.bottom, Metrics.Space.s)
            }

            SSHAuthenticationForm(
                prompt: prompt,
                submit: submit,
                cancel: {
                    conversation.respondToSSHAuthentication(.cancelled)
                },
                usesContainerChrome: false
            )
            // A retry or the next route node must start with fresh SecureFields.
            .id(request.id)
        }
    }

    private func submit(
        identityID: Identity.ID?, username: String, password: String?,
        passphrase: String?, keyID: SSHKeyRef.ID?, save: Bool
    ) {
        conversation.respondToSSHAuthentication(
            .submit(
                AgentSSHAuthenticationAnswer(
                    identityID: identityID,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    keyID: keyID,
                    save: requiresPassphrase ? false : save
                )
            ))
    }
}

private struct AgentSSHHostKeyCard: View {
    let request: AgentSSHHostKeyRequest
    let conversation: ConversationModel

    var body: some View {
        VStack(spacing: 0) {
            if conversation.pendingSSHHostKeys.count > 1 {
                HStack {
                    Spacer()
                    QueueDepthLabel(remaining: conversation.pendingSSHHostKeys.count)
                }
                .padding(.bottom, Metrics.Space.s)
            }
            SSHHostKeyConfirmationForm(
                prompt: request.prompt,
                displayAddress: request.address,
                proceed: { conversation.respondToSSHHostKey(.continueOnce) },
                trust: request.allowsPersistentTrust
                    ? { conversation.respondToSSHHostKey(.trustAndContinue) } : nil,
                deny: { conversation.respondToSSHHostKey(.deny) },
                usesContainerChrome: false
            )
            .id(request.id)
        }
    }
}

/// The agent asking the user to decide one or more things.
///
/// One step at a time rather than a tall form. Answers stay in the model while
/// the user moves back and forth, and Skip makes an intentional null distinct
/// from cancelling the whole request.
///
/// Options are a list rather than a `Picker` because each one carries a
/// sentence explaining what it costs, and a pop-up menu has nowhere to put
/// that. Nothing is preselected — including the recommendation, which is a
/// label and not a default, so that an answer always takes a deliberate click.
/// A question may also be explicitly skipped: the tool reports that as a null
/// and the model decides it itself.
private struct AgentUserInputCard: View {
    let request: AgentUserInputRequest
    let conversation: ConversationModel
    var isCompact = false

    private var isLastQuestion: Bool {
        conversation.currentUserInputQuestionIndex == request.questions.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            if conversation.pendingUserInputs.count > 1 {
                HStack {
                    Spacer()
                    QueueDepthLabel(remaining: conversation.pendingUserInputs.count)
                }
            }

            // Prefer the step's natural height. When the surrounding VStack
            // offers less room, the scrolling fallback accepts that proposal.
            ViewThatFits(in: .vertical) {
                currentQuestion
                ScrollView { currentQuestion }
                    .scrollBounceBehavior(.basedOnSize)
            }

            footer
        }
        .activeFormKeyboardActions(
            isDefaultEnabled: conversation.canAdvanceUserInput,
            onDefault: conversation.advanceUserInputQuestion,
            onCancel: conversation.cancelUserInput
        )
    }

    @ViewBuilder
    private var currentQuestion: some View {
        if let question = conversation.currentUserInputQuestion {
            questionBlock(question)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(question.id)
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.s) {
                Button("Cancel") { conversation.cancelUserInput() }
                    .keyboardShortcut(.cancelAction)
                if conversation.currentUserInputQuestionIndex > 0 {
                    Button("Back") { conversation.previousUserInputQuestion() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            questionProgress
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            HStack(spacing: Metrics.Space.s) {
                if conversation.canSkipUserInputQuestion {
                    Button("Skip") { conversation.skipUserInputQuestion() }
                }
                Button(isLastQuestion ? "Submit" : "Next") {
                    conversation.advanceUserInputQuestion()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!conversation.canAdvanceUserInput)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var questionProgress: some View {
        let current = conversation.currentUserInputQuestionIndex + 1
        if isCompact {
            Text("\(current) / \(request.questions.count)")
        } else {
            Text("Question \(current) of \(request.questions.count)")
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: AgentUserQuestion) -> some View {
        @Bindable var conversation = conversation
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.prompt)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            switch question.kind {
            case .secret:
                SecureField("Secret", text: $conversation.secretInputDraft)
                    .textFieldStyle(.roundedBorder)
            case .choice(let choice):
                choiceList(choice, in: question.id)
            case .text:
                TextField("Answer", text: customBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func choiceList(_ choice: AgentUserInputChoice, in questionID: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            ForEach(choice.options) { option in
                optionRow(option, choice: choice, in: questionID)
            }
            if choice.allowsCustomAnswer {
                customRow(choice, in: questionID)
            }
        }
    }

    private func optionRow(
        _ option: AgentUserInputOption, choice: AgentUserInputChoice, in questionID: String
    ) -> some View {
        let isSelected = conversation.userInputDraft(for: questionID).selection.contains(option.id)
        return Button {
            conversation.answerUserInputOption(option.id, in: questionID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
                Image(systemName: marker(isSelected: isSelected, choice: choice))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: Metrics.Sidebar.rowIcon)

                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    HStack(spacing: Metrics.Space.s) {
                        Text(option.label).font(.callout)
                        if option.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, Metrics.Space.s)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isCompact ? 2 : 3)
                            .truncationMode(.tail)
                            .help(Text(option.detail))
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The escape hatch, sitting in the list as one more choice rather than
    /// below it as an afterthought — an answer the model did not think of is
    /// not a lesser kind of answer.
    private func customRow(_ choice: AgentUserInputChoice, in questionID: String) -> some View {
        let typed = conversation.userInputDraft(for: questionID).text
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
            Image(systemName: marker(isSelected: !typed.isEmpty, choice: choice))
                .foregroundStyle(typed.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: Metrics.Sidebar.rowIcon)

            TextField(
                choice.customPlaceholder.isEmpty
                    ? String(localized: "Something else…") : choice.customPlaceholder,
                text: customBinding(for: questionID)
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private func customBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { conversation.userInputDraft(for: questionID).text },
            set: { conversation.setUserInputCustomAnswer($0, for: questionID) }
        )
    }

    private func marker(isSelected: Bool, choice: AgentUserInputChoice) -> String {
        if choice.allowsMultipleAnswers {
            isSelected ? "checkmark.square.fill" : "square"
        } else {
            isSelected ? "largecircle.fill.circle" : "circle"
        }
    }
}

// MARK: - Steering

/// What the user has said to a busy agent that it has not been told yet.
///
/// Deliberately outside the transcript. These are not turns of the conversation
/// until the run delivers them, and drawing them as bubbles would put words in
/// a place the model never read them. The strip empties itself: each row leaves
/// as its message enters the transcript proper.
struct SteeringQueueView: View {
    let conversation: ConversationModel
    var isCompact = false
    var isEmbedded = false
    var surfaceStyle: AssistantInteractionSurfaceStyle = .standard

    /// The rows' own height, because a `ScrollView` will not report one — left
    /// alone it takes every point it is offered, and the strip would stand at
    /// its ceiling with one line in it. Same problem, and same answer, as the
    /// draft editor's height in `ComposerView`.
    @State private var rowsHeight: CGFloat = 0
    @State private var hoveredMessageID: PendingSteeringMessage.ID?

    /// The wait has two different causes, and only one of them resolves on its
    /// own. While a card above is holding the run, saying "next step" would be
    /// a promise nothing is working towards.
    private var deliveryStatus: LocalizedStringKey {
        switch conversation.runState {
        case .waitingForApproval, .waitingForUser: "Waiting for response"
        default: "Next step"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.s) {
                Label("Steering", systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: Metrics.Space.s)

                Text(deliveryStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

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
            .frame(height: min(rowsHeight, Metrics.Chat.steeringQueueMaxHeight))
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same surface the Composer directly below it uses, so the two read
        // as one object with a queue on top rather than as two panels — see
        // `assistantInteractionSurface`. No hand-drawn stroke: system glass
        // draws its own edge, and a second one on top of it reads as a seam.
        .assistantInteractionSurface(style: surfaceStyle)
        .padding(.horizontal, isEmbedded ? 0 : Metrics.Space.l)
        .padding(.top, Metrics.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Queued messages"))
    }

    /// What was typed, not what will be sent: `message.text` carries the
    /// attachment blocks folded in for the model, and a row of markup is not a
    /// reminder of anything.
    private func row(_ pending: PendingSteeringMessage) -> some View {
        Button {
            conversation.returnSteeringToDraft(pending.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
                Text(pending.draft)
                    .font(.callout)
                    .lineLimit(isCompact ? 1 : 2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !pending.attachments.isEmpty {
                    Label("\(pending.attachments.count)", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: Metrics.Sidebar.rowIcon, height: Metrics.Sidebar.rowIcon)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.Space.s)
            .padding(.vertical, Metrics.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Transparent at rest, so the rows read as content on the surface
            // rather than as chips laid on top of it. The hover fill is the
            // app's one hover level — see `Highlight`.
            .background(
                Highlight.fill(
                    isSelected: false, isHovering: hoveredMessageID == pending.id
                ),
                in: .rect(cornerRadius: Metrics.Radius.medium)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredMessageID = pending.id
            } else if hoveredMessageID == pending.id {
                hoveredMessageID = nil
            }
        }
        .help(Text("Take this back and edit it"))
        .accessibilityLabel(Text("Unqueue message"))
    }
}
