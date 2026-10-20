// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation

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
struct AgentUserInputCard: View {
    let request: AgentUserInputRequest
    let conversation: ConversationModel
    var isCompact = false

    @Environment(AppModel.self) private var app
    @State private var interaction = UserInputInteractionModel()

    private var speechSession: UserInputSpeechSession { interaction.speech }
    @FocusState private var focusedQuestionID: String?

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
            isDefaultEnabled: interaction.canAdvance(in: conversation),
            onDefault: advanceQuestion,
            onCancel: cancelRequest
        )
        .onChange(of: conversation.id) { _, _ in speechSession.cancel() }
        .onDisappear { speechSession.cancel() }
        .alert(
            speechSession.error?.title ?? String(localized: AppStrings.Assistant.transcriptionFailed),
            isPresented: Binding(
                get: { speechSession.error != nil },
                set: { if !$0 { speechSession.dismissError() } })
        ) {
            if speechSession.error?.offersSystemSettings == true {
                Button(AppStrings.Assistant.openSystemSettings.swiftUIKey) { openSpeechSettings() }
            }
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) { speechSession.dismissError() }
        } message: {
            Text(speechSession.error?.message ?? "")
        }
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
                Button(AppStrings.Common.cancel.swiftUIKey, action: cancelRequest)
                    .keyboardShortcut(.cancelAction)
                if conversation.currentUserInputQuestionIndex > 0 {
                    Button(AppStrings.Common.back.swiftUIKey) {
                        interaction.previous(in: conversation)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            questionProgress
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            HStack(spacing: Metrics.Space.s) {
                if conversation.canSkipUserInputQuestion {
                    Button(AppStrings.Common.skip.swiftUIKey) {
                        interaction.skip(in: conversation)
                    }
                }
                Button(isLastQuestion ? AppStrings.Common.submit.swiftUIKey : AppStrings.Common.next.swiftUIKey) {
                    advanceQuestion()
                }
                .transcriptProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!interaction.canAdvance(in: conversation))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var questionProgress: some View {
        let current = conversation.currentUserInputQuestionIndex + 1
        if request.questions.count > 1 {
            if isCompact {
                Text("\(current) / \(request.questions.count)")
            } else {
                Text(AppStrings.Assistant.questionOf(current: current, total: request.questions.count))
            }
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
                RevealableSecretField(
                    AppStrings.Keychain.secret, text: $conversation.secretInputDraft, appearance: .roundedBorder)
            case .choice(let choice):
                choiceList(choice, in: question.id)
            case .text:
                answerField(String(localized: AppStrings.Assistant.answer), questionID: question.id)
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
            interaction.selectOption(option.id, in: questionID, conversation: conversation)
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
        .disabled(speechSession.isActive)
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

            answerField(
                choice.customPlaceholder.isEmpty
                    ? String(localized: AppStrings.Assistant.otherAnswer) : choice.customPlaceholder,
                questionID: questionID
            )
        }
    }

    private func answerField(_ placeholder: String, questionID: String) -> some View {
        HStack(spacing: Metrics.Space.xs) {
            TextField(placeholder, text: customBinding(for: questionID))
                .textFieldStyle(.plain)
                .focused($focusedQuestionID, equals: questionID)
                .disabled(speechSession.isActive)
            UserInputSpeechControls(
                isActive: speechSession.isActive, isRecording: speechSession.isRecording,
                canStart: app.speechTranscription.canStart(for: speechSession.ownerID),
                start: {
                    focusedQuestionID = nil
                    speechSession.start(coordinator: app.speechTranscription, conversation: conversation) {
                        focusedQuestionID = questionID
                    }
                },
                cancel: {
                    speechSession.cancel()
                    focusedQuestionID = questionID
                }, stop: speechSession.stop
            )
        }
        .padding(.leading, Metrics.Space.s)
        .background(.background, in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.secondary.opacity(0.25))
                .allowsHitTesting(false)
        }
    }

    private func advanceQuestion() {
        interaction.advance(in: conversation)
    }

    private func cancelRequest() {
        interaction.cancelRequest(in: conversation)
    }

    private func openSpeechSettings() {
        let anchor =
            speechSession.error?.code == .speechPermissionDenied
            ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
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
