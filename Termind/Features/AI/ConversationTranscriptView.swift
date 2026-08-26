import SwiftUI

/// A conversation rendered as chips + transcript + composer.
///
/// Shared by the session Assistant sidebar and full Assistant tab so the two can never drift; only
/// the padding and the provider header differ.
struct ConversationView: View {
    private enum ScrollTarget: Hashable { case bottom }

    private struct TranscriptScrollMetrics: Equatable {
        let isAtBottom: Bool
        let contentHeight: CGFloat
    }

    let conversation: ConversationModel
    var isCompact: Bool = false
    /// Forwarded to the composer. Only the sidebar has a focused pane to
    /// describe, so only the sidebar passes one.
    var sessionContext: SessionContext = .none
    /// A conversation can be shown on both surfaces. Terminal actions belong
    /// to the Workspace sidebar displaying it, not to the conversation itself.
    var showsTerminalActions = false

    @State private var isAtTranscriptBottom = true
    @State private var isFollowingTranscriptBottom = true
    @State private var isUserScrollingTranscript = false
    @State private var isTranscriptScrollPending = true

    var body: some View {
        VStack(spacing: 0) {
            transcript
            // Each region rules itself off from whatever is above it, so every
            // pair gets exactly one hairline. Ruling *below* instead, which is
            // what these did, put two adjacent lines under any card that was
            // showing — the card's own and the composer's.
            if let approval = conversation.pendingApproval {
                Divider()
                AgentApprovalCard(request: approval, conversation: conversation)
            }
            if let interaction = conversation.pendingUserInteraction {
                switch interaction {
                case .questions(let input):
                    AgentUserInputCard(request: input, conversation: conversation)
                        .padding(.horizontal, Metrics.Space.l)
                        .frame(
                            maxWidth: isCompact ? .infinity : Metrics.Chat.contentMaxWidth
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Metrics.Space.s)
                case .sshAuthentication(let authentication):
                    AgentSSHAuthenticationCard(
                        request: authentication, conversation: conversation
                    )
                }
            }
            if !conversation.pendingSteering.isEmpty {
                SteeringQueueView(conversation: conversation)
            }
            ComposerView(
                conversation: conversation,
                maxContentWidth: isCompact ? nil : Metrics.Chat.contentMaxWidth,
                sessionContext: sessionContext,
                includesTerminalSuggestion: showsTerminalActions
            )
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // No rules between turns. A bubble on one side and unframed
                // prose on the other already separate the speakers, and a line
                // through every gap turns a conversation into a ledger.
                LazyVStack(alignment: .leading, spacing: Metrics.Chat.turnSpacing) {
                    if conversation.isEmpty {
                        emptyState
                    } else {
                        ForEach(conversation.timeline) { item in
                            row(for: item).id(item.id)
                        }
                        if conversation.runState == .interrupted {
                            Label(
                                "This run was interrupted and was not resumed.",
                                systemImage: "pause.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(ScrollTarget.bottom)
                    }
                }
                // Horizontal padding belongs to the column, not to each turn:
                // it is what lines a bubble's trailing edge up with the left
                // edge of unframed assistant text.
                .padding(.horizontal, isCompact ? Metrics.Space.l : Metrics.Space.xl)
                .padding(.vertical, Metrics.Space.xl)
                .frame(
                    maxWidth: isCompact ? .infinity : Metrics.Chat.contentMaxWidth
                )
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                TranscriptScrollMetrics(
                    isAtBottom: geometry.visibleRect.maxY
                        >= geometry.contentSize.height - Metrics.Space.l,
                    contentHeight: geometry.contentSize.height
                )
            } action: { oldMetrics, newMetrics in
                isAtTranscriptBottom = newMetrics.isAtBottom
                if isUserScrollingTranscript {
                    isFollowingTranscriptBottom = newMetrics.isAtBottom
                }

                // A token only needs a scroll when it actually wraps or adds a
                // block. Watching text revisions scheduled work for every token
                // even though most of them did not move the bottom at all.
                if oldMetrics.contentHeight != newMetrics.contentHeight {
                    requestScrollToBottom()
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    isUserScrollingTranscript = true
                    if !isAtTranscriptBottom {
                        isFollowingTranscriptBottom = false
                    }
                case .idle:
                    if isUserScrollingTranscript {
                        isFollowingTranscriptBottom = isAtTranscriptBottom
                    }
                    isUserScrollingTranscript = false
                case .animating:
                    // Programmatic scrolling is not an instruction to stop
                    // following. Only direct user interaction changes it.
                    break
                }
            }
            // Sending a new prompt is an explicit return to the live edge,
            // even if the reader had previously scrolled up through history.
            .onChange(of: conversation.messages.last(where: { $0.role == .user })?.id) {
                requestScrollToBottom(force: true)
            }
            .task(id: isTranscriptScrollPending) {
                // One view-owned debounce coalesces rapid layout changes.
                // Unlike an unstructured Task per token, it is cancelled with
                // the Sidebar and can never retain a stale ScrollViewProxy.
                guard isTranscriptScrollPending else { return }
                do {
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    return
                }

                guard isFollowingTranscriptBottom else {
                    isTranscriptScrollPending = false
                    return
                }
                proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
                isTranscriptScrollPending = false
            }
        }
    }

    private func requestScrollToBottom(force: Bool = false) {
        guard force || isFollowingTranscriptBottom else { return }
        if force { isFollowingTranscriptBottom = true }
        isTranscriptScrollPending = true
    }

    @ViewBuilder
    private func row(for item: TimelineItem) -> some View {
        switch item {
        case .message(let message) where message.role == .user:
            UserMessageView(message: message, isCompact: isCompact)
        case .message(let message):
            AssistantMessageView(
                message: message, isCompact: isCompact,
                showsTerminalActions: showsTerminalActions
            )
        case .tool(let card):
            AgentToolRowView(card: card)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("Start a Conversation")
                .font(.headline)
            Text("Ask a question or describe what you want to do.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tool calls

/// One tool call, as a line the reader can open.
///
/// A filled card per call turns a reply that used four tools into four grey
/// slabs around one paragraph of prose. The one-line action is what people scan
/// for; only the review result and output appear when they ask for more.
private struct AgentToolRowView: View {
    let card: AgentToolCard

    @Environment(AppModel.self) private var app
    @State private var isExpanded = false

    private var summary: String {
        AgentToolPresentation.summary(for: card, hostName: hostName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Button {
                isExpanded.toggle()
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
                        .modifier(ScanningTextMask(isActive: card.state == .running))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: Metrics.Space.s)
                    if card.state == .reviewing {
                        Image(systemName: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text("Security Review in progress"))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .opacity(card.state == .interrupted ? 0.5 : 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(isExpanded ? "Hide details" : "Show details"))

            if isExpanded { detail }
        }
    }

    private var detail: some View {
        HStack(alignment: .top, spacing: Metrics.Space.m) {
            RoundedRectangle(cornerRadius: Metrics.Chat.rule / 2)
                .fill(.quaternary)
                .frame(width: Metrics.Chat.rule)

            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                if let review = card.review {
                    Label(
                        "Security Review: \(review.risk.rawValue.capitalized) — \(review.reason)",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if let result = card.result {
                    if let output = AgentToolPresentation.detailOutput(
                        from: result,
                        presentation: card.descriptor.presentation,
                        review: card.review
                    ) {
                        Text(output)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.caption.monospaced())
                            .foregroundStyle(result.isError ? .red : .secondary)
                            .textSelection(.enabled)
                    }

                    if result.isTruncated {
                        Text("Output truncated")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                Spacer()
                Button("Allow Once") { conversation.respondToApproval(allow: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Metrics.Space.l)
        .background(.orange.opacity(0.08))
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
                }
            )
            // A retry or the next route node must start with fresh SecureFields.
            .id(request.id)
        }
        .padding(Metrics.Space.l)
    }

    private func submit(
        identityID: Identity.ID?, username: String, password: String?,
        passphrase: String?, keyID: SSHKeyRef.ID?, save: Bool
    ) {
        conversation.respondToSSHAuthentication(.submit(
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

/// The agent asking the user to decide one or more things.
///
/// A form rather than a run of cards. A turn's questions are usually one group
/// of decisions, and revealing the second only once the first is answered hides
/// it at the moment it would have informed the first.
///
/// Options are a list rather than a `Picker` because each one carries a
/// sentence explaining what it costs, and a pop-up menu has nowhere to put
/// that. Nothing is preselected — including the recommendation, which is a
/// label and not a default, so that an answer always takes a deliberate click.
/// A question may also be left alone: the tool reports that as a null and the
/// model decides it itself, so the count in the footer is a count and not a
/// validation error, and an unanswered question is marked in no way at all.
private struct AgentUserInputCard: View {
    let request: AgentUserInputRequest
    let conversation: ConversationModel

    private var isForm: Bool { request.questions.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            if conversation.pendingUserInputs.count > 1 {
                HStack {
                    Spacer()
                    QueueDepthLabel(remaining: conversation.pendingUserInputs.count)
                }
            }

            // Prefer the form's natural height. When the surrounding VStack
            // offers less room (including after a live window resize), the
            // scrolling fallback accepts that proposal instead. There is no
            // fixed card height, so one question never inherits the box needed
            // by three long ones.
            ViewThatFits(in: .vertical) {
                questionStack
                ScrollView { questionStack }
                    .scrollBounceBehavior(.basedOnSize)
            }

            footer
        }
        .padding(Metrics.Space.l)
        .background(.bar, in: .rect(cornerRadius: Metrics.Chat.composerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Chat.composerRadius)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var questionStack: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            ForEach(request.questions) { question in
                questionBlock(question)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            Button("Cancel") { conversation.cancelUserInput() }
            Spacer(minLength: 0)
            if isForm {
                Text(
                    "\(conversation.answeredUserInputCount) of \(request.questions.count) answered"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Button("Continue") { conversation.submitUserInput() }
                .buttonStyle(.borderedProminent)
                .disabled(!conversation.canSubmitUserInput)
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
            conversation.toggleUserInputOption(option.id, in: questionID)
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
                            .fixedSize(horizontal: false, vertical: true)
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
private struct SteeringQueueView: View {
    let conversation: ConversationModel

    /// The rows' own height, because a `ScrollView` will not report one — left
    /// alone it takes every point it is offered, and the strip would stand at
    /// its ceiling with one line in it. Same problem, and same answer, as the
    /// draft editor's height in `ComposerView`.
    @State private var rowsHeight: CGFloat = 0

    /// The wait has two different causes, and only one of them resolves on its
    /// own. While a card above is holding the run, saying "next step" would be
    /// a promise nothing is working towards.
    private var caption: LocalizedStringKey {
        switch conversation.runState {
        case .waitingForApproval, .waitingForUser: "Steering — held until you answer above"
        default: "Steering — delivered at the next step"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Label(caption, systemImage: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    ForEach(conversation.pendingSteering) { pending in
                        row(pending)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .frame(height: min(rowsHeight, Metrics.Chat.steeringQueueMaxHeight))
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: .rect(cornerRadius: Metrics.Radius.large))
        .padding(.horizontal, Metrics.Space.l)
        .padding(.top, Metrics.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Queued messages"))
    }

    /// What was typed, not what will be sent: `message.text` carries the
    /// attachment blocks folded in for the model, and a row of markup is not a
    /// reminder of anything.
    private func row(_ pending: PendingSteeringMessage) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Text(pending.draft)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            if !pending.attachments.isEmpty {
                Label("\(pending.attachments.count)", systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: Metrics.Space.s)

            Button {
                conversation.returnSteeringToDraft(pending.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: Metrics.Sidebar.rowIcon, height: Metrics.Sidebar.rowIcon)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Take this back and edit it"))
            .accessibilityLabel(Text("Unqueue message"))
        }
    }
}
