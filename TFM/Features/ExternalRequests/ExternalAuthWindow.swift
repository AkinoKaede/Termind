import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation

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
    @State private var idleDismissal: Task<Void, Never>?
    @State private var displayedRequestID: UUID?
    @State private var displayedPending: ExternalAuthCoordinator.Pending?
    @State private var isClosingAfterIdle = false

    private var pending: ExternalAuthCoordinator.Pending? {
        app.externalAuthentication.current
    }

    var body: some View {
        Group {
            if let visiblePending {
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Text(AppStrings.MCP.requestedBy(visiblePending.clientName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    requestView(visiblePending)
                }
                // The window glass is already the visual container. Keep one
                // generous inset instead of nesting material cards.
                .padding(Metrics.Space.xxl)
            } else {
                Color.clear
            }
        }
        // Authentication requests vary substantially in height. A passphrase
        // request has only one field, while identity and secret requests can
        // contain several rows. Let the content establish the window height so
        // compact requests do not inherit the empty space needed by larger ones.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 520)
        // A background does not contribute an ideal size. The former ZStack's
        // flexible Color accepted the current window height and fed it back to
        // `.windowResizability(.contentSize)`, preventing shorter Passphrase
        // requests from shrinking the window after a taller Identity form.
        .background {
            Color.clear
                .termindGlassSurface(cornerRadius: Metrics.Radius.large)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // SwiftUI otherwise supplies its own opaque window background below
        // the glass view. Clearing both container and NSWindow backgrounds is
        // what leaves a single, genuine material surface.
        .containerBackground(.clear, for: .window)
        .background {
            ExternalAuthWindowChromeBridge(presentationID: pending?.id)
        }
        .onAppear {
            isClosingAfterIdle = false
            displayedRequestID = pending?.id
            displayedPending = pending
            if let id = pending?.id { app.externalAuthentication.markPresented(id) }
        }
        .onChange(of: pending?.id, initial: true) {
            if !isClosingAfterIdle, let pending {
                displayedRequestID = pending.id
                displayedPending = pending
                app.externalAuthentication.markPresented(pending.id)
            }
            updateIdleDismissal()
        }
        .onDisappear {
            idleDismissal?.cancel()
            if !isClosingAfterIdle, app.externalAuthentication.current != nil {
                app.externalAuthentication.windowClosed(presenting: displayedRequestID)
            }
        }
    }

    /// Keep the current form visible across the brief Identity-to-Passphrase
    /// hand-off. The next request replaces it directly; completion closes the
    /// window without an intermediate animation.
    private var visiblePending: ExternalAuthCoordinator.Pending? {
        pending ?? displayedPending
    }

    @ViewBuilder
    private func requestView(_ pending: ExternalAuthCoordinator.Pending) -> some View {
        switch pending.request {
        case .ssh(let request):
            if let signing = request.securityKey {
                AgentSecurityKeySigningCard(request: signing) {
                    app.externalAuthentication.respondSSH($0, requestID: request.id)
                }
            } else {
                DesktopSSHAuthenticationForm(
                    prompt: request.journeyPrompt,
                    submit: { identityID, username, password, passphrase, keyID, save in
                        app.externalAuthentication.respondSSH(
                            .submit(
                                AgentSSHAuthenticationAnswer(
                                    identityID: identityID,
                                    identityName: identityID.flatMap {
                                        app.hostLibrary.identity($0)?.name
                                    },
                                    username: username, password: password,
                                    passphrase: passphrase, keyID: keyID,
                                    save: request.requiresPassphrase ? false : save
                                )
                            ), requestID: request.id
                        )
                    },
                    cancel: { app.externalAuthentication.respondSSH(.cancelled, requestID: request.id) },
                    usesContainerChrome: false,
                    respondKeyboardInteractive: {
                        app.externalAuthentication.respondSSH(.keyboardInteractive($0), requestID: request.id)
                    }
                )
                .id(pending.id)
            }
        case .secret(let request):
            ExternalSecretRequestForm(
                request: request,
                hostName: request.hostID.flatMap { app.hostLibrary.host($0)?.name },
                submit: { response in
                    app.externalAuthentication.respondSecret(response)
                }
            )
            .id(pending.id)
        case .hostKey(let request):
            DesktopSSHHostKeyConfirmationForm(
                prompt: request.prompt,
                displayAddress: request.address,
                proceed: {
                    app.externalAuthentication.respondHostKey(.continueOnce)
                },
                trust: request.allowsPersistentTrust
                    ? {
                        app.externalAuthentication.respondHostKey(.trustAndContinue)
                    } : nil,
                deny: {
                    app.externalAuthentication.respondHostKey(.deny)
                },
                usesContainerChrome: false
            )
            .id(pending.id)
        }
    }

    private func updateIdleDismissal() {
        idleDismissal?.cancel()
        idleDismissal = nil
        guard pending == nil else { return }

        // An SSH flow can answer Identity, briefly empty the coordinator, and
        // immediately enqueue Passphrase for the selected protected key. Do not
        // interpret that hand-off as completion: give the resumed resolver one
        // main-actor turn to publish its next checkpoint before closing. The
        // small bounded grace also avoids a visible close/reopen flash.
        idleDismissal = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard app.externalAuthentication.current == nil else { return }
            isClosingAfterIdle = true
            dismissWindow(id: ExternalAuthWindowPresenter.sceneID)
        }
    }
}

/// Native chrome and presentation policy for the external authentication scene.
@MainActor
enum ExternalAuthWindowChrome {
    static func configure(_ window: NSWindow, presentsRequest: Bool = false) {
        window.styleMask.insert([
            .titled, .closable, .miniaturizable, .fullSizeContentView,
        ])
        window.title = String(localized: AppStrings.Connections.authenticationRequest)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])

        for button in [
            NSWindow.ButtonType.closeButton,
            NSWindow.ButtonType.miniaturizeButton,
            NSWindow.ButtonType.zoomButton,
        ] {
            window.standardWindowButton(button)?.isHidden = false
        }

        if presentsRequest {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            // FocusState may resolve during the same layout pass that attached
            // this bridge. Reassert key status once the SecureField exists.
            Task { @MainActor [weak window] in window?.makeKey() }
        }
    }
}

private struct ExternalAuthWindowChromeBridge: NSViewRepresentable {
    let presentationID: UUID?

    func makeNSView(context: Context) -> ExternalAuthWindowChromeBridgeView {
        ExternalAuthWindowChromeBridgeView()
    }

    func updateNSView(_ view: ExternalAuthWindowChromeBridgeView, context: Context) {
        view.configureWindow(presentationID: presentationID)
    }
}

private final class ExternalAuthWindowChromeBridgeView: NSView {
    private var presentedRequestID: UUID?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow(presentationID: nil)
    }

    func configureWindow(presentationID: UUID?) {
        guard let window else { return }
        let presentsRequest = presentationID != nil && presentationID != presentedRequestID
        presentedRequestID = presentationID
        ExternalAuthWindowChrome.configure(window, presentsRequest: presentsRequest)
    }
}

/// Secret-only checkpoint used by the external `request_user_secret` tool.
private struct ExternalSecretRequestForm: View {
    let request: AgentUserInputRequest
    let hostName: String?
    let submit: (AgentUserInputResponse) -> Void

    @State private var secret = ""
    @FocusState private var isFocused: Bool

    private var question: AgentUserQuestion? { request.questions.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Label(AppStrings.MCP.secretInput.swiftUIKey, systemImage: "key.fill")
                .font(.headline)
            if let question {
                Text(question.prompt)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hostName {
                LabeledContent(AppStrings.MCP.destination.swiftUIKey, value: hostName)
            }
            if !request.purpose.isEmpty {
                LabeledContent(AppStrings.MCP.purpose.swiftUIKey, value: request.purpose)
            }
            RevealableSecretField(AppStrings.Keychain.secret, text: $secret, appearance: .roundedBorder)
                .focused($isFocused)
            Text(
                AppStrings.MCP.secretHandleExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppStrings.Common.continue.swiftUIKey) { submitSecret() }
                    .transcriptProminentButtonStyle()
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
        var bytes = Data(secret.utf8)
        secret = ""
        submit(
            .answered([
                AgentUserInputAnswer(
                    questionID: question.id,
                    value: .secret(AgentSecret(consumingUTF8: &bytes))
                )
            ]))
    }

    private func cancel() {
        secret = ""
        submit(.cancelled)
    }
}
