import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

extension View {
    fileprivate func transcriptProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .foregroundStyle(TermindColor.transcriptProminentForeground)
    }
}

private struct ConversationAttachmentDropModifier: ViewModifier {
    let conversation: ConversationModel
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targetedKind: NativeDropKind?

    private var acceptsAttachments: Bool {
        isEnabled
            && !conversation.isArchived
            && conversation.pendingUserInteraction == nil
            && conversation.pendingApproval == nil
    }

    func body(content: Content) -> some View {
        content
            .overlay { decoration }
            .overlay {
                NativeDropTarget(
                    targetedKind: $targetedKind,
                    acceptedKinds: [.files, .images],
                    isEnabled: acceptsAttachments,
                    receive: receive
                )
            }
            .animation(
                Motion.dropTarget(reduceMotion: reduceMotion),
                value: targetedKind
            )
    }

    @ViewBuilder
    private var decoration: some View {
        if targetedKind != nil {
            DropTargetOverlay(
                presentation: DropTargetPresentation(
                    title: String(localized: AppStrings.Assistant.attachToChat),
                    detail: String(localized: AppStrings.Assistant.filesAndImages),
                    systemImage: targetedKind == .images
                        ? "photo.badge.plus" : "paperclip"
                ))
        }
    }

    private func receive(_ payload: NativeDropPayload) -> Bool {
        var accepted = false
        if !payload.fileURLs.isEmpty {
            conversation.importAttachmentFiles(payload.fileURLs)
            accepted = true
        }
        if !payload.images.isEmpty {
            conversation.importAttachmentImages(
                payload.images, label: String(localized: AppStrings.Assistant.droppedImage)
            )
            accepted = true
        }
        return accepted
    }
}

extension View {
    func conversationAttachmentDropTarget(
        conversation: ConversationModel,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            ConversationAttachmentDropModifier(
                conversation: conversation,
                isEnabled: isEnabled
            )
        )
    }
}

/// A conversation rendered as chips + transcript + composer.
///
/// Shared by the session Assistant sidebar and full Assistant destination so the two can never drift; only
/// the padding and the provider header differ.
struct ConversationView: View {
    enum Region: Equatable {
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

    var body: some View {
        Group {
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
        .conversationAttachmentDropTarget(
            conversation: conversation,
            isEnabled: region == .all
        )
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
                        isEmbedded: true
                    )
                }
            }
            ComposerView(
                conversation: conversation,
                maxContentWidth: isCompact ? nil : Metrics.Chat.contentMaxWidth,
                sessionContext: sessionContext,
                terminalSuggestionsAvailable: showsTerminalActions,
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
                .composerBlock()
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
            Label(AppStrings.Assistant.archivedConversationsAreReadOnly.swiftUIKey, systemImage: "archivebox")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppStrings.Assistant.unarchive.swiftUIKey) {
                window.setAssistantArchived(conversation.id, archived: false)
            }
            .transcriptProminentButtonStyle()
        }
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
        case .mcpAuthorization(let prompt):
            MCPAuthorizationCard(prompt: prompt, conversation: conversation).id(prompt.id)
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
            .composerBlock()
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
            showsTerminalActions: showsTerminalActions
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

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let timeline = conversation.timeline
        let entries = TranscriptEntry.items(
            timeline: timeline,
            isInterrupted: conversation.runState == .interrupted,
            canEdit: conversation.canEditUserMessage,
            canFork: conversation.canForkAssistantMessage
        )
        let owner = window.transcriptCache.owner(
            for: .init(
                conversationID: conversation.id,
                surface: isCompact ? .sidebar : .fullScreen
            )
        )
        return TranscriptListView(
            owner: owner,
            entries: entries,
            latestUserMessageID: conversation.messages.last(where: { $0.role == .user })?.id,
            configuration: .init(
                isCompact: isCompact,
                showsTerminalActions: showsTerminalActions,
                isConversationStreaming: conversation.isStreaming,
                chatDestinations: Dictionary(
                    uniqueKeysWithValues: window.assistantLibrary.conversations.map {
                        ($0.id, $0.derivedTitle)
                    }),
                locale: locale,
                reduceMotion: reduceMotion,
                colorScheme: colorScheme
            ),
            actions: .init(
                hostName: { id in
                    app.hostLibrary.host(id)?.name ?? String(id.uuidString.prefix(8))
                },
                navigateChat: { window.selectAssistant($0) },
                editUserMessage: { id, text in
                    window.editAssistantUserMessage(
                        conversation.id,
                        messageID: id,
                        text: text,
                        context: sessionContext,
                        terminalSuggestionsAvailable: showsTerminalActions
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
                    app.sendPlanImplementation(
                        card, in: conversation, context: sessionContext,
                        terminalSuggestionsAvailable: showsTerminalActions, window: window)
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
            )
        )
        // A representable coordinator is retained at one structural position.
        // Conversation or surface changes must therefore replace the mount
        // bridge instead of letting an old owner receive the new transcript.
        .id(owner.key)
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
                Text(
                    AppStrings.Assistant.step(
                        completed: conversation.completedTaskCount, total: conversation.tasks.count)
                )
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
        .help(
            Text(
                AppStrings.Assistant.ofTasksDone(
                    completedTaskCount: conversation.completedTaskCount, count: conversation.tasks.count))
        )
        .accessibilityLabel(
            Text(
                AppStrings.Assistant.tasksOfDone(
                    completed: conversation.completedTaskCount, total: conversation.tasks.count))
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
        .accessibilityLabel(Text(AppStrings.Assistant.tasks))
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

// MARK: - Decisions

/// Kept as an emphasised card on purpose. This is the one place in the
/// transcript that is waiting on a person, and the de-emphasis the rest of this
/// view got would make it read like history.
private struct AgentApprovalCard: View {
    @ScaledMetric(relativeTo: .caption) private var approvalHeight: CGFloat = 240
    let request: AgentApprovalRequest
    let conversation: ConversationModel

    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @State private var showsSafetyDetails = false

    var body: some View {
        let presentation = AgentToolPresentation.approval(
            for: request,
            presenter: TermindAgentTools.presenter(for: request.descriptor),
            hostName: request.invocation.targetHostID.map(hostName),
            locale: locale
        )
        return VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack {
                Label(AppStrings.Assistant.approvalRequired.swiftUIKey, systemImage: "hand.raised.fill").font(
                    .headline)
                Spacer()
                QueueDepthLabel(remaining: conversation.pendingApprovals.count)
            }

            HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(presentation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
            }

            ViewThatFits(in: .vertical) {
                approvalDetails(presentation)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    approvalDetails(presentation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: AgentToolPresentation.usesCompactDetails(for: request.descriptor) ? approvalHeight : nil)

            HStack {
                Button(AppStrings.Common.deny.swiftUIKey, role: .destructive) {
                    conversation.respondToApproval(request.id, allow: false)
                }
                .accessibilityIdentifier("AssistantApproval.Deny")
                Spacer()
                Button(AppStrings.Assistant.allowOnce.swiftUIKey) {
                    conversation.respondToApproval(request.id, allow: true)
                }
                .transcriptProminentButtonStyle()
                .accessibilityIdentifier("AssistantApproval.AllowOnce")
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AssistantApproval.Card")
        .activeFormKeyboardActions(
            isDefaultEnabled: true,
            onDefault: { conversation.respondToApproval(request.id, allow: true) },
            onCancel: { conversation.respondToApproval(request.id, allow: false) }
        )
    }

    private func approvalDetails(_ presentation: AgentApprovalPresentation) -> some View {
        AssistantApprovalDetails(
            detail: presentation.detail,
            reasons: request.localReasons,
            showsSafetyDetails: $showsSafetyDetails
        )
    }

    private func hostName(_ id: UUID) -> String {
        app.hostLibrary.host(id)?.name ?? String(id.uuidString.prefix(8))
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
            Text(AppStrings.Assistant.firstQuestionOf(remaining))
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

            DesktopSSHAuthenticationForm(
                prompt: request.journeyPrompt,
                submit: submit,
                cancel: {
                    conversation.respondToSSHAuthentication(.cancelled, requestID: request.id)
                },
                usesContainerChrome: false,
                respondKeyboardInteractive: {
                    conversation.respondToSSHAuthentication(.keyboardInteractive($0), requestID: request.id)
                }
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
                    save: request.requiresPassphrase ? false : save
                )
            ), requestID: request.id)
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
            DesktopSSHHostKeyConfirmationForm(
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
                Button(AppStrings.Common.cancel.swiftUIKey) { conversation.cancelUserInput() }
                    .keyboardShortcut(.cancelAction)
                if conversation.currentUserInputQuestionIndex > 0 {
                    Button(AppStrings.Common.back.swiftUIKey) { conversation.previousUserInputQuestion() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            questionProgress
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            HStack(spacing: Metrics.Space.s) {
                if conversation.canSkipUserInputQuestion {
                    Button(AppStrings.Common.skip.swiftUIKey) { conversation.skipUserInputQuestion() }
                }
                Button(isLastQuestion ? AppStrings.Common.submit.swiftUIKey : AppStrings.Common.next.swiftUIKey) {
                    conversation.advanceUserInputQuestion()
                }
                .transcriptProminentButtonStyle()
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
            Text(AppStrings.Assistant.questionOf(current: current, total: request.questions.count))
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
                RevealableSecretField(AppStrings.Keychain.secret, text: $conversation.secretInputDraft)
                    .textFieldStyle(.roundedBorder)
            case .choice(let choice):
                choiceList(choice, in: question.id)
            case .text:
                TextField(AppStrings.Assistant.answer.swiftUIKey, text: customBinding(for: question.id))
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
                            Text(AppStrings.Assistant.recommended)
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
                    ? String(localized: AppStrings.Assistant.otherAnswer) : choice.customPlaceholder,
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

    /// The rows' own height, because a `ScrollView` will not report one — left
    /// alone it takes every point it is offered, and the strip would stand at
    /// its ceiling with one line in it. Same problem, and same answer, as the
    /// draft editor's height in `ComposerView`.
    @State private var rowsHeight: CGFloat = 0
    @State private var hoveredMessageID: PendingSteeringMessage.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
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
            .frame(height: min(rowsHeight, Metrics.Chat.steeringQueueMaxHeight))
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same surface the Composer directly below it uses, so the two read
        // as one object with a queue on top rather than as two panels — see
        // `assistantInteractionSurface`. No hand-drawn stroke: system glass
        // draws its own edge, and a second one on top of it reads as a seam.
        .assistantInteractionSurface()
        .padding(.horizontal, isEmbedded ? 0 : Metrics.Space.l)
        .padding(.top, Metrics.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Assistant.queuedMessages))
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
        .help(Text(AppStrings.Assistant.takeThisBackAndEditIt))
        .accessibilityLabel(Text(AppStrings.Assistant.unqueueMessage))
    }
}
