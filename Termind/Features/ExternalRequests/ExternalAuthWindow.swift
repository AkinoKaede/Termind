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
                .padding(Metrics.Space.l)
            } else {
                ProgressView().padding(Metrics.Space.xxl)
            }
        }
        .frame(minWidth: 520, minHeight: 310)
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
                    app.externalAuthentication.respondSSH(.submit(
                        AgentSSHAuthenticationAnswer(
                            identityID: identityID,
                            identityName: identityID.flatMap { app.hosts.identity($0)?.name },
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
                }
            )
            .id(pending.id)
        case .secret(let request):
            ExternalSecretRequestForm(
                request: request,
                hostName: request.hostID.flatMap { app.hosts.host($0)?.name },
                submit: { response in
                    app.externalAuthentication.respondSecret(response)
                    dismissIfFinished()
                }
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
                .onSubmit { submitSecret() }
            Text(
                "Termind returns only a one-shot handle to the MCP client. The value is bound to this session, destination, ssh_exec, and purpose."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { cancel() }
                Spacer()
                Button("Continue") { submitSecret() }
                    .buttonStyle(.borderedProminent)
                    .disabled(secret.isEmpty || question == nil)
            }
        }
        .onAppear { isFocused = true }
        .onDisappear { secret = "" }
    }

    private func submitSecret() {
        guard let question, !secret.isEmpty else { return }
        let value = secret
        secret = ""
        submit(.answered([
            AgentUserInputAnswer(questionID: question.id, value: .secret(value))
        ]))
    }

    private func cancel() {
        secret = ""
        submit(.cancelled)
    }
}
