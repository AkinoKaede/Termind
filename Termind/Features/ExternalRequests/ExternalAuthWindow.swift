import SwiftUI

struct ExternalAuthWindowPresenter: View {
    static let sceneID = "external-ssh-authentication"

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: app.externalAuthentication.presentationRevision, initial: true) {
                guard app.externalAuthentication.current != nil else { return }
                openWindow(id: Self.sceneID)
            }
    }
}

struct ExternalAuthWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    private var pending: ExternalAuthCoordinator.Pending? {
        app.externalAuthentication.current
    }

    var body: some View {
        Group {
            if let pending {
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Text("Requested by \(pending.clientName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    requestView(pending)
                }
                // The window is already the visual container. Keep one generous
                // inset around both request kinds instead of nesting the SSH
                // form's material card inside it.
                .padding(Metrics.Space.xxl)
            } else {
                ProgressView().padding(Metrics.Space.xxl)
            }
        }
        // Authentication requests vary substantially in height. A passphrase
        // request has only one field, while identity and secret requests can
        // contain several rows. Let the content establish the window height so
        // compact requests do not inherit the empty space needed by larger ones.
        .frame(minWidth: 520)
        .onChange(of: pending?.id) {
            if pending == nil {
                dismissWindow(id: ExternalAuthWindowPresenter.sceneID)
            }
        }
        .onDisappear {
            if app.externalAuthentication.current != nil {
                app.externalAuthentication.windowClosed()
            }
        }
    }

    @ViewBuilder
    private func requestView(_ pending: ExternalAuthCoordinator.Pending) -> some View {
        switch pending.request {
        case .ssh(let request):
            SSHAuthenticationForm(
                prompt: prompt(for: request),
                submit: { identityID, username, password, passphrase, keyID, save in
                    let requiresPassphrase: Bool
                    if case .passphrase = request.mode {
                        requiresPassphrase = true
                    } else {
                        requiresPassphrase = false
                    }
                    app.externalAuthentication.respondSSH(
                        .submit(
                            AgentSSHAuthenticationAnswer(
                                identityID: identityID,
                                identityName: identityID.flatMap { app.hostLibrary.identity($0)?.name },
                                username: username, password: password,
                                passphrase: passphrase, keyID: keyID,
                                save: requiresPassphrase ? false : save
                            )
                        ))
                    dismissIfFinished()
                },
                cancel: {
                    app.externalAuthentication.respondSSH(.cancelled)
                    dismissIfFinished()
                },
                usesContainerChrome: false
            )
            .id(pending.id)
        case .secret(let request):
            ExternalSecretRequestForm(
                request: request,
                hostName: request.hostID.flatMap { app.hostLibrary.host($0)?.name },
                submit: { response in
                    app.externalAuthentication.respondSecret(response)
                    dismissIfFinished()
                }
            )
            .id(pending.id)
        case .hostKey(let request):
            SSHHostKeyConfirmationForm(
                prompt: request.prompt,
                displayAddress: request.address,
                proceed: {
                    app.externalAuthentication.respondHostKey(.continueOnce)
                    dismissIfFinished()
                },
                trust: request.allowsPersistentTrust
                    ? {
                        app.externalAuthentication.respondHostKey(.trustAndContinue)
                        dismissIfFinished()
                    } : nil,
                deny: {
                    app.externalAuthentication.respondHostKey(.deny)
                    dismissIfFinished()
                },
                usesContainerChrome: false
            )
            .id(pending.id)
        }
    }

    private func prompt(for request: AgentSSHAuthenticationRequest) -> SSHAuthenticationPrompt {
        let requiresPassphrase: Bool
        if case .passphrase = request.mode { requiresPassphrase = true } else { requiresPassphrase = false }
        return SSHAuthenticationPrompt(
            host: Host(id: request.hostID, name: request.displayName, host: request.address),
            selectedIdentityID: request.selectedIdentityID,
            username: request.username,
            selectedKeyID: request.selectedKeyID,
            failureMessage: request.failureMessage,
            requiresPassphrase: requiresPassphrase,
            mode: request.failureMessage == nil ? .localIdentity : .serverChallenge
        )
    }

    private func dismissIfFinished() {
        guard app.externalAuthentication.current == nil else { return }
        dismissWindow(id: ExternalAuthWindowPresenter.sceneID)
    }
}

private struct ExternalSecretRequestForm: View {
    let request: AgentUserInputRequest
    let hostName: String?
    let submit: (AgentUserInputResponse) -> Void

    @State private var secret = ""
    @FocusState private var isFocused: Bool

    private var question: AgentUserQuestion? { request.questions.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Label("Secret input", systemImage: "key.fill")
                .font(.headline)
            if let question {
                Text(question.prompt)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hostName {
                LabeledContent("Destination", value: hostName)
            }
            if !request.purpose.isEmpty {
                LabeledContent("Purpose", value: request.purpose)
            }
            SecureField("Secret", text: $secret)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            Text(
                "Termind returns only a one-shot handle to the MCP client. The value is bound to this session, destination, ssh_exec, and purpose."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { submitSecret() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty || question == nil)
            }
        }
        .activeFormKeyboardActions(
            isDefaultEnabled: !secret.isEmpty && question != nil,
            onDefault: submitSecret,
            onCancel: cancel
        )
        .onAppear { isFocused = true }
        .onDisappear { secret = "" }
    }

    private func submitSecret() {
        guard let question, !secret.isEmpty else { return }
        let value = secret
        secret = ""
        submit(
            .answered([
                AgentUserInputAnswer(questionID: question.id, value: .secret(value))
            ]))
    }

    private func cancel() {
        secret = ""
        submit(.cancelled)
    }
}
