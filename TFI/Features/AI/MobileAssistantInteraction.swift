import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure

struct MobileAssistantInteraction: View {
    @ScaledMetric(relativeTo: .caption) private var approvalHeight: CGFloat = 240
    @Bindable var conversation: ConversationModel
    let hosts: HostLibraryModel
    @FocusState private var focusedInput: InputFocus?
    @Environment(\.locale) private var locale
    @State private var expandedApprovalID: UUID?

    private enum InputFocus: Hashable {
        case text(String)
        case secret(String)
        case custom(String)
    }

    var body: some View {
        // The earliest checkpoint across both queues is the only visible form.
        if let approval = conversation.pendingApproval,
            conversation.pendingUserInteraction.map({ approval.invocation.createdAt <= $0.createdAt }) ?? true
        {
            approvalCard(approval)
                .mobileAssistantInteractionSurface()
        } else if let interaction = conversation.pendingUserInteraction {
            switch interaction {
            case .sshAuthentication(let request):
                MobileAssistantAdaptiveHeight {
                    VStack(alignment: .leading, spacing: 8) {
                        MobileAssistantQueueDepthLabel(remaining: conversation.pendingSSHAuthentications.count)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        MobileAssistantAuthenticationForm(request: request, conversation: conversation, hosts: hosts)
                    }
                }
                .mobileAssistantInteractionSurface()
            case .sshHostKey(let request):
                MobileAssistantAdaptiveHeight {
                    VStack(alignment: .leading, spacing: 8) {
                        MobileAssistantQueueDepthLabel(remaining: conversation.pendingSSHHostKeys.count)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        MobileAssistantHostKeyForm(request: request, conversation: conversation)
                    }
                }
                .mobileAssistantInteractionSurface()
            case .questions:
                questions
                    .mobileAssistantInteractionSurface()
            }
        }
    }

    private func approvalCard(_ approval: AgentApprovalRequest) -> some View {
        let presentation = AgentToolPresentation.approval(
            for: approval,
            presenter: TermindAgentTools.presenter(for: approval.descriptor),
            hostName: approval.invocation.targetHostID.map(hostName),
            locale: locale
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AppStrings.Assistant.approvalRequired.swiftUIKey, systemImage: "hand.raised.fill")
                    .font(.headline)
                Spacer()
                MobileAssistantQueueDepthLabel(remaining: conversation.pendingApprovals.count)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(presentation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
            }

            ViewThatFits(in: .vertical) {
                approvalDetails(presentation, approval: approval)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    approvalDetails(presentation, approval: approval)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: AgentToolPresentation.usesCompactDetails(for: approval.descriptor) ? approvalHeight : nil)

            HStack {
                Button(AppStrings.Common.deny.swiftUIKey, systemImage: "xmark", role: .destructive) {
                    conversation.respondToApproval(approval.id, allow: false)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("AssistantApproval.Deny")
                Spacer()
                Button(AppStrings.Assistant.allowOnce.swiftUIKey, systemImage: "checkmark") {
                    conversation.respondToApproval(approval.id, allow: true)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("AssistantApproval.AllowOnce")
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AssistantApproval.Card")
    }

    private func approvalDetails(
        _ presentation: AgentApprovalPresentation,
        approval: AgentApprovalRequest
    ) -> some View {
        AssistantApprovalDetails(
            detail: presentation.detail,
            reasons: approval.localReasons,
            showsSafetyDetails: safetyDetailsBinding(for: approval.id)
        )
    }

    private func safetyDetailsBinding(for approvalID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedApprovalID == approvalID },
            set: { expandedApprovalID = $0 ? approvalID : nil }
        )
    }

    private func hostName(_ id: UUID) -> String {
        hosts.host(id)?.name ?? String(id.uuidString.prefix(8))
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if conversation.pendingUserInputs.count > 1 {
                HStack {
                    Spacer()
                    MobileAssistantQueueDepthLabel(remaining: conversation.pendingUserInputs.count)
                }
            }
            if let question = conversation.currentUserInputQuestion {
                // Match TFM: the decision controls remain reachable while only
                // the current question gives way to scrolling.
                ViewThatFits(in: .vertical) {
                    questionBlock(question)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    scrollingQuestion(question)
                }
                footer(for: question)
            }
        }
    }

    private func scrollingQuestion(_ question: AgentUserQuestion) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                questionBlock(question)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(question.id)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: question.id, initial: true) { _, id in
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: AgentUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                secretField(for: question)
            case .text:
                textField(for: question)
            case .choice(let choice):
                choiceList(choice, in: question.id)
            }
        }
    }

    private func secretField(for question: AgentUserQuestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            RevealableSecretField(AppStrings.Keychain.secret, text: $conversation.secretInputDraft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedInput, equals: .secret(question.id))
                .submitLabel(isLastQuestion ? .done : .next)
                .onSubmit { advanceFromKeyboard(question.id) }
        }
        .questionInputSurface()
        .contentShape(.rect)
        .onTapGesture { focusedInput = .secret(question.id) }
    }

    private func textField(for question: AgentUserQuestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.cursor")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            TextField(AppStrings.Assistant.answer.swiftUIKey, text: answer(question.id), axis: .vertical)
                .lineLimit(1...3)
                .focused($focusedInput, equals: .text(question.id))
                .submitLabel(isLastQuestion ? .done : .next)
                .onSubmit { advanceFromKeyboard(question.id) }
        }
        .questionInputSurface()
        .contentShape(.rect)
        .onTapGesture { focusedInput = .text(question.id) }
    }

    private func choiceList(_ choice: AgentUserInputChoice, in questionID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choice.options) { option in
                optionRow(option, choice: choice, in: questionID)
            }
            if choice.allowsCustomAnswer {
                customRow(choice, in: questionID)
            }
        }
    }

    private func optionRow(
        _ option: AgentUserInputOption,
        choice: AgentUserInputChoice,
        in questionID: String
    ) -> some View {
        let isSelected = conversation.userInputDraft(for: questionID).selection.contains(option.id)
        return Button {
            conversation.answerUserInputOption(option.id, in: questionID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: marker(isSelected: isSelected, choice: choice))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(option.label)
                            .font(.callout.weight(.medium))
                        if option.isRecommended {
                            Text(AppStrings.Assistant.recommended)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: .capsule)
                                .foregroundStyle(.tint)
                                .fixedSize()
                        }
                    }
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .questionOptionSurface(isSelected: isSelected)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func customRow(_ choice: AgentUserInputChoice, in questionID: String) -> some View {
        let typed = conversation.userInputDraft(for: questionID).text
        let isSelected = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: marker(isSelected: isSelected, choice: choice))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            customAnswerField(choice, in: questionID)
                .focused($focusedInput, equals: .custom(questionID))
                .submitLabel(isLastQuestion ? .done : .next)
                .onSubmit { advanceFromKeyboard(questionID) }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .questionOptionSurface(isSelected: isSelected)
        .contentShape(.rect)
        .onTapGesture { focusedInput = .custom(questionID) }
    }

    @ViewBuilder
    private func customAnswerField(_ choice: AgentUserInputChoice, in questionID: String) -> some View {
        if choice.customPlaceholder.isEmpty {
            TextField(AppStrings.Assistant.otherAnswer.swiftUIKey, text: answer(questionID))
        } else {
            TextField(choice.customPlaceholder, text: answer(questionID))
        }
    }

    private func footer(for question: AgentUserQuestion) -> some View {
        VStack(spacing: 8) {
            Divider()
            ViewThatFits(in: .horizontal) {
                wideFooter(for: question)
                compactFooter(for: question)
            }
        }
    }

    private func wideFooter(for question: AgentUserQuestion) -> some View {
        HStack(spacing: 10) {
            leadingActions
                .frame(maxWidth: .infinity, alignment: .leading)
            questionProgress
            trailingActions(for: question)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func compactFooter(for question: AgentUserQuestion) -> some View {
        VStack(spacing: 4) {
            HStack {
                questionProgress
                Spacer(minLength: 8)
                if conversation.canSkipUserInputQuestion {
                    skipButton
                }
            }
            HStack(spacing: 10) {
                leadingActions
                Spacer(minLength: 8)
                primaryButton(for: question)
            }
        }
    }

    private var leadingActions: some View {
        HStack(spacing: 10) {
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { conversation.cancelUserInput() }
                .keyboardShortcut(MobileShortcut.formCancel)
            if conversation.currentUserInputQuestionIndex > 0 {
                Button(AppStrings.Common.back.swiftUIKey) { conversation.previousUserInputQuestion() }
            }
        }
        .frame(minHeight: 44)
    }

    private func trailingActions(for question: AgentUserQuestion) -> some View {
        HStack(spacing: 10) {
            if conversation.canSkipUserInputQuestion {
                skipButton
            }
            primaryButton(for: question)
        }
        .frame(minHeight: 44)
    }

    private var skipButton: some View {
        Button(AppStrings.Common.skip.swiftUIKey) { conversation.skipUserInputQuestion() }
    }

    private func primaryButton(for question: AgentUserQuestion) -> some View {
        Button(isLastQuestion ? AppStrings.Common.submit.swiftUIKey : AppStrings.Common.next.swiftUIKey) {
            advanceFromKeyboard(question.id)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(MobileShortcut.formDefault)
        .disabled(!conversation.canAdvanceUserInput)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var questionProgress: some View {
        Text(
            AppStrings.Assistant.questionOf(
                current: conversation.currentUserInputQuestionIndex + 1,
                total: conversation.pendingUserInput?.questions.count ?? 0)
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var isLastQuestion: Bool {
        conversation.currentUserInputQuestionIndex + 1
            == (conversation.pendingUserInput?.questions.count ?? 0)
    }

    private func advanceFromKeyboard(_ questionID: String) {
        guard conversation.currentUserInputQuestion?.id == questionID,
            conversation.canAdvanceUserInput
        else { return }
        conversation.advanceUserInputQuestion()
    }

    private func marker(isSelected: Bool, choice: AgentUserInputChoice) -> String {
        if choice.allowsMultipleAnswers {
            isSelected ? "checkmark.square.fill" : "square"
        } else {
            isSelected ? "largecircle.fill.circle" : "circle"
        }
    }

    private func answer(_ id: String) -> Binding<String> {
        Binding(
            get: { conversation.userInputDraft(for: id).text },
            set: { conversation.setUserInputCustomAnswer($0, for: id) })
    }
}

private struct MobileAssistantQueueDepthLabel: View {
    let remaining: Int

    var body: some View {
        if remaining > 1 {
            Text(AppStrings.Assistant.firstQuestionOf(remaining))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    fileprivate func questionInputSurface() -> some View {
        frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    fileprivate func questionOptionSurface(isSelected: Bool) -> some View {
        background(
            isSelected ? Color.accentColor.opacity(0.1) : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
    }
}

private struct MobileAssistantAdaptiveHeight<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // The Assistant's bottom safe-area inset supplies the real ceiling,
        // including keyboard avoidance. A local cap wastes usable screen space.
        ViewThatFits(in: .vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MobileAssistantAuthenticationForm: View {
    let request: AgentSSHAuthenticationRequest
    let conversation: ConversationModel
    let hosts: HostLibraryModel
    var body: some View {
        SSHAuthenticationForm(
            prompt: request.journeyPrompt,
            submit: { identity, username, password, passphrase, key, save in
                conversation.respondToSSHAuthentication(
                    .submit(
                        .init(
                            identityID: identity, identityName: nil,
                            username: username, password: password, passphrase: passphrase, keyID: key, save: save)),
                    requestID: request.id)
            }, cancel: { conversation.respondToSSHAuthentication(.cancelled, requestID: request.id) },
            usesContainerChrome: false,
            library: hosts,
            respondKeyboardInteractive: {
                conversation.respondToSSHAuthentication(.keyboardInteractive($0), requestID: request.id)
            }
        )
        .id(request.id)
    }
}

private struct MobileAssistantHostKeyForm: View {
    let request: AgentSSHHostKeyRequest
    let conversation: ConversationModel
    var body: some View {
        SSHHostKeyConfirmationForm(
            prompt: request.prompt, displayAddress: request.address,
            proceed: { conversation.respondToSSHHostKey(.continueOnce) },
            trust: request.allowsPersistentTrust ? { conversation.respondToSSHHostKey(.trustAndContinue) } : nil,
            deny: { conversation.respondToSSHHostKey(.deny) }, usesContainerChrome: false
        ).id(request.id)
    }
}
