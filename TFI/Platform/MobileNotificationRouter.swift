import Foundation
import TermindApplication

@MainActor
final class MobileNotificationRouter {
    private weak var app: MobileAppModel?
    private var pendingAssistant: UUID?
    private var pendingTransfers = false
    private var loading: Task<Void, Never>?
    private var stopped = false
    private let activate: @MainActor (String) -> Void

    init(
        app: MobileAppModel,
        activate: @escaping @MainActor (String) -> Void = MobileNotificationPlatform.activate
    ) {
        self.app = app
        self.activate = activate
    }

    func open(_ target: NotificationTarget) {
        guard !stopped, let app else { return }
        switch target {
        case .transfers:
            pendingTransfers = true
            resume()
        case .terminal(let id): app.openCommandNotification(id)
        case .assistant(let id):
            pendingAssistant = id
            resume()
        }
    }

    func resume() {
        guard !stopped, let app else { return }
        if pendingTransfers, let scene = app.selectTransferNotificationTarget() {
            pendingTransfers = false
            activate(scene.workspaceSession.id)
        }
        guard pendingAssistant != nil, loading == nil else { return }
        loading = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer { loading = nil }
            await app.assistant.load()
            guard !stopped, let id = pendingAssistant, let scene = app.selectAssistantNotificationTarget(id) else {
                return
            }
            pendingAssistant = nil
            activate(scene.workspaceSession.id)
        }
    }

    func stop() {
        stopped = true
        pendingAssistant = nil
        pendingTransfers = false
        loading?.cancel()
        loading = nil
    }
}
