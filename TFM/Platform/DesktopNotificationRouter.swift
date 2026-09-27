import AppKit
import TermindApplication

/// Owns pending notification navigation while window selection remains app-owned.
@MainActor
final class DesktopNotificationRouter {
    private weak var app: AppModel?
    private var pendingAssistant: UUID?
    private var loading: Task<Void, Never>?
    private var stopped = false
    private let activate: @MainActor (WindowModel) -> Void

    init(app: AppModel, activate: (@MainActor (WindowModel) -> Void)? = nil) {
        self.app = app
        self.activate = activate ?? { [weak app] in app?.mainWindows.activate($0) }
    }

    func open(_ target: NotificationTarget) {
        guard !stopped, let app else { return }
        switch target {
        case .transfers: app.mainWindows.showTransfers()
        case .terminal(let id): app.openCommandNotification(id)
        case .assistant(let id):
            pendingAssistant = id
            if app.notificationWindows.isEmpty { app.mainWindows.newWindow() }
            guard loading == nil else { return }
            loading = Task { [weak self, weak app] in
                guard let self, let app else { return }
                defer { loading = nil }
                do {
                    try await app.restoreAssistantConversations()
                    resume()
                } catch {
                    guard !stopped else { return }
                    for window in app.notificationWindows {
                        window.assistantOperationError = error.localizedDescription
                    }
                }
            }
        }
    }

    func resume() {
        guard !stopped, let app, let id = pendingAssistant,
            let window = app.selectAssistantNotificationTarget(id)
        else { return }
        pendingAssistant = nil
        activate(window)
    }

    func stop() {
        stopped = true
        pendingAssistant = nil
        loading?.cancel()
        loading = nil
    }
}
