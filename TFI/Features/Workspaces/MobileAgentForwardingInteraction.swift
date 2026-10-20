// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation

/// Each scene owns its pending requests. No UIKit presentation singleton is used.
@MainActor
@Observable
final class MobileAgentForwardingInteraction {
    enum Request: Identifiable {
        case keyboard(SSHKeyboardInteractiveChallenge)
        case securityKey(SecurityKeySigningRequest)
        var id: UUID {
            switch self {
            case .keyboard(let request): request.id
            case .securityKey(let request): request.id
            }
        }
    }
    private(set) var pending: [Request] = []
    private var signingWaiters: [UUID: CheckedContinuation<SecurityKeyAssertion, any Error>] = [:]
    private var waiters: [UUID: CheckedContinuation<[String], any Error>] = [:]
    var isActive = false {
        didSet { if !isActive { cancelAll() } }
    }
    var current: Request? { pending.first }

    func request(_ challenge: SSHKeyboardInteractiveChallenge) async throws -> [String] {
        guard isActive, pending.count < 16 else { throw SSHInteractionRequired() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[challenge.id] = continuation
                pending.append(.keyboard(challenge))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.respond(challenge.id, answers: nil) }
        }
    }
    func respond(_ id: UUID, answers: [String]?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        if let answers { waiter.resume(returning: answers) } else { waiter.resume(throwing: CancellationError()) }
    }
    func sign(_ request: SecurityKeySigningRequest) async throws -> SecurityKeyAssertion {
        guard isActive, pending.count < 16 else { throw SSHInteractionRequired() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                signingWaiters[request.id] = continuation
                pending.append(.securityKey(request))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.respond(request.id, result: .failure(CancellationError())) }
        }
    }

    func respond(_ id: UUID, result: Result<SecurityKeyAssertion, any Error>) {
        guard let waiter = signingWaiters.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        waiter.resume(with: result)
    }

    func cancelAll() {
        for id in Array(signingWaiters.keys) { respond(id, result: .failure(CancellationError())) }
        for id in Array(waiters.keys) { respond(id, answers: nil) }
    }
}

@MainActor
final class MobileAgentForwardingRouter {
    private struct Entry {
        weak var scene: MobileSceneModel?
    }
    private var scenes: [UUID: Entry] = [:]
    func register(_ scene: MobileSceneModel) { scenes[scene.id] = Entry(scene: scene) }
    func context(for request: SSHConnectionRequest) -> SSHAgentInteractionContext {
        let live = scenes.values.compactMap(\.scene)
        let candidates: [MobileSceneModel]
        if let contextID = request.agentForwardingContextID {
            candidates = live.filter { scene in
                scene.workspaceSession.workspaces.contains { $0.id == contextID }
                    || scene.assistant.library.selectedConversationID == contextID
            }
        } else {
            candidates = live.filter { $0.agentForwarding.isActive }
        }
        // An ambiguous or inactive owner cannot authorize a signature.
        guard candidates.count == 1, let scene = candidates.first else {
            return SSHAgentInteractionContext(canInteract: { false })
        }
        let presenter = scene.agentForwarding
        return SSHAgentInteractionContext(
            unlock: { [weak presenter] challenge in
                guard let presenter else { throw CancellationError() }
                return try await presenter.request(challenge)
            },
            securityKeySigning: { [weak presenter] request in
                guard let presenter else { throw CancellationError() }
                return try await presenter.sign(request)
            },
            canInteract: { [weak presenter] in presenter?.isActive == true })
    }
}

struct MobileAgentForwardingSheet: View {
    let interaction: MobileAgentForwardingInteraction
    let request: MobileAgentForwardingInteraction.Request
    var body: some View {
        NavigationStack {
            Group {
                switch request {
                case .keyboard(let challenge):
                    SSHKeyboardInteractiveForm(
                        challenge: challenge,
                        submit: { interaction.respond(challenge.id, answers: $0) },
                        cancel: { interaction.respond(challenge.id, answers: nil) })
                case .securityKey(let signing):
                    SecurityKeySigningCard(request: signing) { interaction.respond(signing.id, result: $0) }
                }
            }
            .padding()
            .navigationTitle(AppStrings.Connections.agentForwarding.swiftUIKey)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
