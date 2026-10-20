// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import AuthenticationServices
import SwiftUI
import TermindApplication
import TermindPresentation

nonisolated enum MCPWebAuthenticationError: LocalizedError, Equatable {
    case sessionUnavailable

    var errorDescription: String? {
        String(localized: AppStrings.MCP.oauthSessionUnavailable)
    }
}

/// Each presenter belongs to the exact window containing the triggering control.
@MainActor
final class MCPWebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var anchor: NSWindow?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var requestID: UUID?

    var interaction: MCPAuthorizationInteraction {
        MCPAuthorizationInteraction { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.authorize(request)
        }
    }

    func authorize(_ request: MCPAuthorizationRequest) async throws -> URL {
        guard session == nil, anchor != nil else { throw MCPOAuthError.authorizationRequired }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                requestID = request.id
                let completion = Self.completionHandler { [weak self] result in
                    guard let self, self.requestID == request.id else { return }
                    self.finish(result)
                }
                let session = ASWebAuthenticationSession(
                    url: request.url,
                    callback: .https(
                        host: request.redirectURI.host!,
                        path: URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false)!.path),
                    completionHandler: completion)
                self.session = session
                session.presentationContextProvider = self
                if !session.start() { finish(.failure(MCPOAuthError.authorizationRequired)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == request.id else { return }
                self?.cancel()
            }
        }
    }

    // Safari can deliver this callback on an XPC queue. Its entry point must not inherit MainActor.
    nonisolated static func completionHandler(
        _ receive: @escaping @MainActor @Sendable (Result<URL, any Error>) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callback, error in
            Task { @MainActor in
                if let callback {
                    receive(.success(callback))
                } else if let reason = (error as NSError?)?.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
                    !reason.isEmpty
                {
                    // The system also reports setup failures (including missing domain association) as canceledLogin.
                    receive(.failure(MCPWebAuthenticationError.sessionUnavailable))
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    receive(.failure(CancellationError()))
                } else {
                    receive(.failure(MCPWebAuthenticationError.sessionUnavailable))
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `authorize` refuses to start before the view has a real window.
        anchor ?? ASPresentationAnchor()
    }

    func cancel() {
        session?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, any Error>) {
        let continuation = continuation
        self.continuation = nil
        session = nil
        requestID = nil
        continuation?.resume(with: result)
    }
}

struct MCPAuthorizationAnchor: NSViewRepresentable {
    let presenter: MCPWebAuthenticationPresenter

    final class AnchorView: NSView {
        weak var presenter: MCPWebAuthenticationPresenter?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presenter?.anchor = window
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.presenter = presenter
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.presenter = presenter
        presenter.anchor = view.window
    }
}

struct MCPAuthorizationCard: View {
    let prompt: MCPAuthorizationPrompt
    let conversation: ConversationModel
    @State private var presenter = MCPWebAuthenticationPresenter()
    @State private var task: Task<Void, Never>?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppStrings.MCP.oauthAuthorization.swiftUIKey, systemImage: "person.badge.key.fill")
                .font(.headline)
            Text(prompt.request.serverName).font(.body.weight(.medium))
            Text(prompt.request.issuer.host ?? "").font(.caption).foregroundStyle(.secondary)
            if !prompt.request.scopes.isEmpty {
                Text(AppStrings.MCP.oauthPermissions).font(.caption.weight(.medium))
                Text(prompt.request.scopes.joined(separator: ", "))
                    .font(.caption).textSelection(.enabled)
            }
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) {
                    task?.cancel()
                    presenter.cancel()
                    conversation.respondToMCPAuthorization(prompt.id, result: .failure(CancellationError()))
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(AppStrings.MCP.oauthAuthorizeContinue.swiftUIKey) {
                    running = true
                    task = Task {
                        do {
                            let callback = try await presenter.authorize(prompt.request)
                            conversation.respondToMCPAuthorization(prompt.id, result: .success(callback))
                        } catch {
                            conversation.respondToMCPAuthorization(prompt.id, result: .failure(error))
                        }
                        running = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }
        }
        .padding()
        .background(MCPAuthorizationAnchor(presenter: presenter).frame(width: 0, height: 0))
        .onDisappear {
            task?.cancel()
            presenter.cancel()
        }
        .accessibilityIdentifier("MCPAuthorization.Card")
    }
}
