import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileAssistantInteraction: View {
    @Bindable var conversation: ConversationModel
    let hosts: HostLibraryModel

    var body: some View {
        // The earliest checkpoint across both queues is the only visible form.
        if let approval = conversation.pendingApproval,
            conversation.pendingUserInteraction.map({ approval.invocation.createdAt <= $0.createdAt }) ?? true
        {
            VStack(alignment: .leading, spacing: 8) {
                Text("Approval Required").font(.headline)
                Text(approval.descriptor.name).font(.callout.monospaced())
                ScrollView {
                    Text(approval.invocation.call.arguments.displayText).font(.caption.monospaced()).textSelection(
                        .enabled
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
                ForEach(approval.localReasons, id: \.self) { Text($0).font(.caption) }
                HStack {
                    Button("Deny", systemImage: "xmark", role: .cancel) { conversation.respondToApproval(allow: false) }
                    Spacer()
                    Button("Allow", systemImage: "checkmark") { conversation.respondToApproval(allow: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if let interaction = conversation.pendingUserInteraction {
            ScrollView {
                switch interaction {
                case .sshAuthentication(let request):
                    SharedMobileAuthentication(request: request, conversation: conversation, hosts: hosts)
                case .sshHostKey(let request):
                    SharedMobileHostKey(request: request, conversation: conversation)
                case .questions:
                    questions
                }
            }.frame(maxHeight: 300)
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = conversation.currentUserInputQuestion {
                Text(question.header).font(.headline)
                Text(question.prompt)
                switch question.kind {
                case .secret:
                    SecureField("Secret", text: $conversation.secretInputDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                case .text:
                    TextField("Answer", text: answer(question.id), axis: .vertical)
                case .choice(let choice):
                    ForEach(choice.options) { option in
                        Button {
                            conversation.toggleUserInputOption(option.id, in: question.id)
                        } label: {
                            HStack(alignment: .top) {
                                Image(
                                    systemName: conversation.userInputDraft(for: question.id).selection.contains(
                                        option.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if !option.detail.isEmpty {
                                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if choice.allowsCustomAnswer { TextField("Answer", text: answer(question.id), axis: .vertical) }
                }
                HStack {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { conversation.cancelUserInput() }
                    if conversation.currentUserInputQuestionIndex > 0 {
                        Button("Back", systemImage: "chevron.left") { conversation.previousUserInputQuestion() }
                    }
                    Spacer()
                    if conversation.canSkipUserInputQuestion {
                        Button("Skip", systemImage: "forward.end") { conversation.skipUserInputQuestion() }
                    }
                    if conversation.currentUserInputQuestionIndex + 1
                        < (conversation.pendingUserInput?.questions.count ?? 0)
                    {
                        Button("Next", systemImage: "chevron.right") { conversation.advanceUserInputQuestion() }
                            .disabled(!conversation.canAdvanceUserInput)
                    } else {
                        Button("Submit", systemImage: "checkmark") { conversation.submitUserInput() }.disabled(
                            !conversation.canSubmitUserInput)
                    }
                }
            }
        }
    }

    private func answer(_ id: String) -> Binding<String> {
        Binding(
            get: { conversation.userInputDraft(for: id).text },
            set: { conversation.setUserInputCustomAnswer($0, for: id) })
    }
}

private struct SharedMobileAuthentication: View {
    let request: AgentSSHAuthenticationRequest
    let conversation: ConversationModel
    let hosts: HostLibraryModel
    var body: some View {
        SharedSSHAuthenticationForm(
            prompt: request.journeyPrompt,
            submit: { identity, username, password, passphrase, key, save in
                conversation.respondToSSHAuthentication(
                    .submit(
                        .init(
                            identityID: identity, identityName: nil,
                            username: username, password: password, passphrase: passphrase, keyID: key, save: save)))
            }, cancel: { conversation.respondToSSHAuthentication(.cancelled) }, usesContainerChrome: false,
            library: hosts
        )
        .id(request.id)
    }
}

private struct SharedMobileHostKey: View {
    let request: AgentSSHHostKeyRequest
    let conversation: ConversationModel
    var body: some View {
        SharedSSHHostKeyConfirmationForm(
            prompt: request.prompt, displayAddress: request.address,
            proceed: { conversation.respondToSSHHostKey(.continueOnce) },
            trust: request.allowsPersistentTrust ? { conversation.respondToSSHHostKey(.trustAndContinue) } : nil,
            deny: { conversation.respondToSSHHostKey(.deny) }, usesContainerChrome: false
        ).id(request.id)
    }
}

extension AgentJSONValue {
    var displayText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
