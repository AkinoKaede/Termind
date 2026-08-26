import SwiftUI

/// A conversation rendered as chips + transcript + composer.
///
/// Shared by the session Assistant sidebar and full Assistant tab so the two can never drift; only
/// the padding and the provider header differ.
struct ConversationView: View {
    let conversation: ConversationModel
    var isCompact: Bool = false
    /// Forwarded to the composer. Only the sidebar has a focused pane to
    /// describe, so only the sidebar passes one.
    var sessionContext: SessionContext = .none

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let approval = conversation.pendingApproval {
                AgentApprovalCard(request: approval, conversation: conversation)
                Divider()
            }
            if let input = conversation.pendingUserInput {
                AgentUserInputCard(request: input, conversation: conversation)
                Divider()
            }
            Divider()
            ComposerView(conversation: conversation, sessionContext: sessionContext)
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
                    }
                }
                // Horizontal padding belongs to the column, not to each turn:
                // it is what lines a bubble's trailing edge up with the left
                // edge of unframed assistant text.
                .padding(.horizontal, isCompact ? Metrics.Space.l : Metrics.Space.xl)
                .padding(.vertical, Metrics.Space.xl)
                .frame(maxWidth: isCompact ? .infinity : 760)
                .frame(maxWidth: .infinity)
            }
            // Keyed on the last row's revision, not on a count. Streaming text
            // grows one message without adding a row, so a count never changed
            // and the transcript stopped following the reply it was showing.
            .onChange(of: conversation.timeline.last?.revision) {
                guard let last = conversation.timeline.last else { return }
                withAnimation(Motion.tabSwitch) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(for item: TimelineItem) -> some View {
        switch item {
        case .message(let message) where message.role == .user:
            UserMessageView(message: message, isCompact: isCompact)
        case .message(let message):
            AssistantMessageView(message: message, isCompact: isCompact)
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
/// slabs around one paragraph of prose. The state is what people scan for; the
/// arguments and output are what they open when the state surprises them.
private struct AgentToolRowView: View {
    let card: AgentToolCard

    /// `nil` until the reader has an opinion, after which theirs wins. Before
    /// that the row follows its state, so a call that starts running opens and
    /// a call that finishes does not slam shut under the pointer.
    @State private var userExpanded: Bool?

    private var isExpanded: Bool {
        userExpanded ?? card.state.revealsDetailByDefault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Button {
                userExpanded = !isExpanded
            } label: {
                HStack(spacing: Metrics.Space.s) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .frame(width: Metrics.Sidebar.rowIcon)
                    Text(card.descriptor.name)
                        .font(MarkdownTypography.body)
                    Spacer(minLength: Metrics.Space.s)
                    Text(card.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
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
                Text(
                    AgentSensitiveDataRedactor
                        .redactedJSON(card.invocation.call.arguments).encodedString
                )
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)

                if let review = card.review {
                    Label(
                        "Security Review: \(review.risk.rawValue.capitalized) — \(review.reason)",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let result = card.result {
                    Text(result.content)
                        .font(.caption.monospaced())
                        .foregroundStyle(result.isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
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

    private var symbol: String {
        switch card.state {
        case .reviewing: "checkmark.shield"
        case .running: "gearshape.2"
        case .completed: "checkmark.circle.fill"
        case .denied, .failed: "xmark.octagon"
        default: "wrench.and.screwdriver"
        }
    }

    private var tint: Color {
        switch card.state {
        case .denied, .failed: .red
        case .reviewing, .waitingForApproval: .orange
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
            Text(request.descriptor.name).font(.callout.weight(.semibold))
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

/// The agent asking the user to decide something.
///
/// Options are a list rather than a `Picker` because each one carries a
/// sentence explaining what it costs, and a pop-up menu has nowhere to put
/// that. Nothing is preselected — including the recommendation, which is a
/// label and not a default, so that an answer always takes a deliberate click.
private struct AgentUserInputCard: View {
    let request: AgentUserInputRequest
    let conversation: ConversationModel

    var body: some View {
        @Bindable var conversation = conversation
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack {
                if !request.header.isEmpty {
                    Text(request.header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                QueueDepthLabel(remaining: conversation.pendingUserInputs.count)
            }
            Text(request.prompt)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            switch request.kind {
            case .secret:
                SecureField("Secret", text: $conversation.secretInputDraft)
                    .textFieldStyle(.roundedBorder)
            case .choice(let choice):
                choiceList(choice)
            case .text:
                TextField("Answer", text: $conversation.userInputDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { conversation.cancelUserInput() }
                Spacer()
                Button("Continue") { conversation.submitUserInput() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!conversation.canSubmitUserInput)
            }
        }
        .padding(Metrics.Space.l)
    }

    private func choiceList(_ choice: AgentUserInputChoice) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            ForEach(choice.options) { option in
                optionRow(option, choice: choice)
            }
            if choice.allowsCustomAnswer {
                customRow(choice)
            }
        }
    }

    private func optionRow(_ option: AgentUserInputOption, choice: AgentUserInputChoice)
        -> some View
    {
        let isSelected = conversation.userInputSelection.contains(option.id)
        return Button {
            conversation.toggleUserInputOption(option.id)
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
    private func customRow(_ choice: AgentUserInputChoice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
            Image(
                systemName: marker(
                    isSelected: !conversation.userInputDraft.isEmpty, choice: choice
                )
            )
            .foregroundStyle(
                conversation.userInputDraft.isEmpty
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)
            )
            .frame(width: Metrics.Sidebar.rowIcon)

            TextField(
                choice.customPlaceholder.isEmpty
                    ? String(localized: "Something else…") : choice.customPlaceholder,
                text: Binding(
                    get: { conversation.userInputDraft },
                    set: { conversation.setUserInputCustomAnswer($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private func marker(isSelected: Bool, choice: AgentUserInputChoice) -> String {
        if choice.allowsMultipleAnswers {
            isSelected ? "checkmark.square.fill" : "square"
        } else {
            isSelected ? "largecircle.fill.circle" : "circle"
        }
    }
}
