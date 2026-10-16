import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

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
struct QueueDepthLabel: View {
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

            if let signing = request.securityKey {
                AgentSecurityKeySigningCard(request: signing) {
                    conversation.respondToSSHAuthentication($0, requestID: request.id)
                }
            } else {
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
