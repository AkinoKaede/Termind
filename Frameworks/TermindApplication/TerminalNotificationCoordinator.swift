// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// Shares delivery policy while the apps retain terminal identity, focus and native sound handling.
@MainActor
public final class TerminalNotificationCoordinator {
    private let service: any NotificationSending
    private let preferences: () -> NotificationPreferences
    private let isFocused: (UUID) -> Bool
    private let title: (UUID) -> String?
    private let body: @MainActor (TerminalCommandCompletion) -> String
    private let ringBell: @MainActor () -> Void
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stopped = false

    public init(
        service: any NotificationSending,
        preferences: @escaping () -> NotificationPreferences,
        isFocused: @escaping (UUID) -> Bool,
        title: @escaping (UUID) -> String?,
        body: @escaping @MainActor (TerminalCommandCompletion) -> String,
        ringBell: @escaping @MainActor () -> Void
    ) {
        self.service = service
        self.preferences = preferences
        self.isFocused = isFocused
        self.title = title
        self.body = body
        self.ringBell = ringBell
    }

    public func observe(_ monitor: TerminalCommandMonitor, id: UUID) {
        monitor.preferences = preferences
        monitor.isWorkspaceFocused = { [weak self] in self?.isFocused(id) ?? false }
        monitor.alert = { [weak self] completion, settings in
            self?.receive(completion, settings: settings, id: id)
        }
    }

    public func stop() {
        stopped = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func receive(_ completion: TerminalCommandCompletion, settings: NotificationPreferences, id: UUID) {
        guard !stopped, let title = title(id) else { return }
        if settings.terminalDelivery == .bell {
            ringBell()
            return
        }
        let notification = AppNotification(target: .terminal(id), title: title, body: body(completion))
        tasks[notification.id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[notification.id] = nil }
            await service.send(notification) { [weak self] in
                guard let self, !stopped, self.title(id) != nil else { return false }
                let settings = preferences()
                return settings.terminalDelivery == .systemNotifications
                    && settings.allowsTerminal(duration: completion.duration, isFocused: isFocused(id))
            }
        }
    }
}
