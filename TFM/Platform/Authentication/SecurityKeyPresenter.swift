// Copyright (C) 2026 Kaede Akino
import AppKit
import AuthenticationServices
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

@MainActor
final class SecurityKeyPresenter: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    weak var anchor: ASPresentationAnchor?
    private var controller: ASAuthorizationController?
    private nonisolated enum Response: Sendable {
        case registration(credentialID: Data, attestation: Data, clientDataJSON: Data)
        case assertion(SecurityKeyAssertion)
    }
    private var operationID: UUID?
    private var completion: ((Result<Response, any Error>) -> Void)?

    func register(name: String, userVerification: SecurityKeyCredential.UserVerification) async throws
        -> SecurityKeyCredential
    {
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
            relyingPartyIdentifier: SecurityKeyCredential.relyingParty)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, displayName: name, name: name, userID: Data(UUID().uuidString.utf8))
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
        request.residentKeyPreference = .discouraged
        request.userVerificationPreference = preference(userVerification)
        guard case .registration(let credentialID, let attestation, let clientDataJSON) = try await perform(request)
        else { throw WebAuthnSSH.Failure.invalidResponse }
        return try WebAuthnSSH.registration(
            credentialID: credentialID, attestation: attestation,
            clientDataJSON: clientDataJSON, challenge: challenge,
            userVerification: userVerification)
    }

    func sign(_ input: SecurityKeySigningRequest) async throws -> SecurityKeyAssertion {
        guard input.allowsUserInteraction else { throw SSHInteractionRequired() }
        try WebAuthnSSH.validate(input.credential)
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
            relyingPartyIdentifier: SecurityKeyCredential.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: input.challenge)
        request.allowedCredentials = [.init(credentialID: input.credential.credentialID, transports: [])]
        request.userVerificationPreference = preference(input.credential.userVerification)
        guard case .assertion(let response) = try await perform(request) else {
            throw WebAuthnSSH.Failure.invalidResponse
        }
        return response
    }

    private func preference(_ value: SecurityKeyCredential.UserVerification)
        -> ASAuthorizationPublicKeyCredentialUserVerificationPreference
    {
        switch value {
        case .required: .required
        case .preferred: .preferred
        case .discouraged: .discouraged
        }
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> Response {
        guard controller == nil, anchor != nil else { throw SSHInteractionRequired() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operationID = id
                completion = { continuation.resume(with: $0) }
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.cancel()
            }
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard controller === self.controller else { return }
        if let credential = authorization.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration,
            let attestation = credential.rawAttestationObject
        {
            finish(
                .success(
                    .registration(
                        credentialID: credential.credentialID, attestation: attestation,
                        clientDataJSON: credential.rawClientDataJSON)))
        } else if let credential = authorization.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion {
            finish(
                .success(
                    .assertion(
                        SecurityKeyAssertion(
                            credentialID: credential.credentialID,
                            authenticatorData: credential.rawAuthenticatorData,
                            clientDataJSON: credential.rawClientDataJSON,
                            signature: credential.signature))))
        } else {
            finish(.failure(WebAuthnSSH.Failure.invalidResponse))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        guard controller === self.controller else { return }
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }

    func cancel() {
        let controller = controller
        finish(.failure(CancellationError()))
        controller?.cancel()
    }

    private func finish(_ result: Result<Response, any Error>) {
        let completion = completion
        self.completion = nil
        operationID = nil
        controller = nil
        completion?(result)
    }
}

struct SecurityKeySigningCard: View {
    let request: SecurityKeySigningRequest
    @State private var presenter: SecurityKeyPresenter
    @State private var session: SecurityKeySigningSession

    init(request: SecurityKeySigningRequest, coordinator: SecurityKeySigningCoordinator) {
        self.init(request: request) { coordinator.respond(request.id, result: $0) }
    }

    init(
        request: SecurityKeySigningRequest,
        respond: @escaping @MainActor (Result<SecurityKeyAssertion, any Error>) -> Void
    ) {
        self.request = request
        let presenter = SecurityKeyPresenter()
        _presenter = State(initialValue: presenter)
        _session = State(
            initialValue: SecurityKeySigningSession(
                sign: { try await presenter.sign(request) }, respond: respond))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill").font(.headline)
            Text(verbatim: request.keyName).font(.subheadline)
            Text(AppStrings.SecurityKey.touchPrompt).foregroundStyle(.secondary)
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if session.isRunning { ProgressView().controlSize(.small) }
                Button(AppStrings.SecurityKey.continueAction.swiftUIKey) { session.start() }
                    .disabled(session.isRunning || session.isFinished)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SecurityKeyAnchor(presenter: presenter, onReady: autoContinue).frame(width: 0, height: 0))
        .onDisappear { cancel() }
    }

    private func autoContinue() {
        guard presenter.anchor != nil else { return }
        session.startAutomatically()
    }

    private func cancel() {
        session.cancel()
        presenter.cancel()
    }
}

struct SecurityKeyAnchor: NSViewRepresentable {
    let presenter: SecurityKeyPresenter
    var onReady: (() -> Void)? = nil
    final class AnchorView: NSView {
        weak var presenter: SecurityKeyPresenter?
        var onReady: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presenter?.anchor = window
            if window != nil { Task { @MainActor [weak self] in self?.onReady?() } }
        }
    }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.presenter = presenter
        view.onReady = onReady
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.presenter = presenter
        presenter.anchor = view.window
        view.onReady = onReady
        if view.window != nil { Task { @MainActor [weak view] in view?.onReady?() } }
    }
}

struct AgentSecurityKeySigningCard: View {
    let request: SecurityKeySigningRequest
    let respond: (AgentSSHAuthenticationResponse) -> Void

    var body: some View {
        SecurityKeySigningCard(request: request) { result in
            switch result {
            case .success(let assertion): respond(.securityKey(assertion))
            case .failure(let error) where error is CancellationError: respond(.cancelled)
            case .failure(let error): respond(.securityKeyFailed(error.localizedDescription))
            }
        }
        .id(request.id)
    }
}
