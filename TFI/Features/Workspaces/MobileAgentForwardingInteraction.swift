import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation

/// Each scene owns its pending requests. No UIKit presentation singleton is used.
@MainActor
@Observable
final class MobileAgentForwardingInteraction {
    private(set) var pending: [SSHKeyboardInteractiveChallenge] = []
    private var waiters: [UUID: CheckedContinuation<[String], any Error>] = [:]
    var isActive = false {
        didSet { if !isActive { cancelAll() } }
    }
    var current: SSHKeyboardInteractiveChallenge? { pending.first }

    func request(_ challenge: SSHKeyboardInteractiveChallenge) async throws -> [String] {
        guard isActive, pending.count < 16 else { throw SSHInteractionRequired() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[challenge.id] = continuation
                pending.append(challenge)
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
    func cancelAll() {
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
            canInteract: { [weak presenter] in presenter?.isActive == true })
    }
}

struct MobileAgentForwardingSheet: View {
    let interaction: MobileAgentForwardingInteraction
    let challenge: SSHKeyboardInteractiveChallenge
    var body: some View {
        NavigationStack {
            SSHKeyboardInteractiveForm(
                challenge: challenge,
                submit: { interaction.respond(challenge.id, answers: $0) },
                cancel: { interaction.respond(challenge.id, answers: nil) }
            )
            .padding()
            .navigationTitle(AppStrings.Connections.agentForwarding.swiftUIKey)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
