// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

@MainActor
final class MobileNotificationRouter {
    private weak var app: MobileAppModel?
    private var pendingTerminal: UUID?
    private var pendingAssistant: UUID?
    private var pendingTransfers = false
    private var activationRequests: [Route: ActivationRequest] = [:]
    private var assistantLoadTask: Task<Void, Never>?
    private var stopped = false
    private let activate: @MainActor (String, @escaping @MainActor () -> Void) -> Void

    private enum Route: Hashable { case terminal, assistant, transfers }

    private struct ActivationRequest: Equatable {
        let sessionID: String
        let id = UUID()
    }

    init(
        app: MobileAppModel,
        activate: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void =
            MobileNotificationPlatform.activate
    ) {
        self.app = app
        self.activate = activate
    }

    func open(_ target: NotificationTarget) {
        guard !stopped, app != nil else { return }
        switch target {
        case .transfers:
            pendingTransfers = true
            activationRequests[.transfers] = nil
        case .terminal(let id):
            pendingTerminal = id
            activationRequests[.terminal] = nil
        case .assistant(let id):
            pendingAssistant = id
            activationRequests[.assistant] = nil
        }
        resume()
    }

    func resume() {
        guard !stopped, let app else { return }
        resumeTerminal(app: app)
        resumeTransfers(app: app)
        resumeAssistant(app: app)
    }

    private func resumeTransfers(app: MobileAppModel) {
        guard pendingTransfers, let scene = app.transferNotificationTarget() else { return }
        guard app.isNotificationSceneActive(scene) else {
            requestActivation(scene.workspaceSession.id, for: .transfers, app: app)
            return
        }
        pendingTransfers = false
        activationRequests[.transfers] = nil
        scene.openTransfers()
    }

    private func resumeAssistant(app: MobileAppModel) {
        guard let id = pendingAssistant, assistantLoadTask == nil, let scene = app.assistantNotificationTarget(id)
        else {
            return
        }
        guard app.isNotificationSceneActive(scene) else {
            requestActivation(scene.workspaceSession.id, for: .assistant, app: app)
            return
        }
        assistantLoadTask = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer {
                assistantLoadTask = nil
                if pendingAssistant != nil { resume() }
            }
            await app.assistant.load()
            guard !stopped, let id = pendingAssistant, let scene = app.assistantNotificationTarget(id),
                app.isNotificationSceneActive(scene)
            else {
                return
            }
            pendingAssistant = nil
            activationRequests[.assistant] = nil
            scene.openAssistantNotification(id)
        }
    }

    private func resumeTerminal(app: MobileAppModel) {
        guard let id = pendingTerminal else { return }
        guard app.workspaces.contains(where: { $0.id == id }), let sessionID = app.workspaceOwner(id) else {
            pendingTerminal = nil
            activationRequests[.terminal] = nil
            return
        }
        if let scene = app.commandNotificationTarget(in: sessionID), app.isNotificationSceneActive(scene) {
            pendingTerminal = nil
            activationRequests[.terminal] = nil
            scene.selectWorkspace(id)
        } else {
            requestActivation(sessionID, for: .terminal, app: app)
        }
    }

    private func requestActivation(_ sessionID: String, for route: Route, app: MobileAppModel) {
        // UIKit brings the app forward for a notification. Only request activation to switch windows.
        guard app.hasActiveNotificationScene, activationRequests[route]?.sessionID != sessionID else { return }
        let request = ActivationRequest(sessionID: sessionID)
        activationRequests[route] = request
        activate(sessionID) { [weak self] in
            // A late failure for an earlier click must not clear the newer request to the same window.
            guard let self, self.activationRequests[route] == request else { return }
            self.activationRequests[route] = nil
        }
    }

    func stop() {
        stopped = true
        pendingTerminal = nil
        pendingAssistant = nil
        pendingTransfers = false
        activationRequests.removeAll()
        assistantLoadTask?.cancel()
        assistantLoadTask = nil
    }
}
