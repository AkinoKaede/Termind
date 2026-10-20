// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// Collects this session's results until no queued or running transfers remain.
/// Paused transfers do not hold up a notification; resuming them starts new work.
@MainActor
public final class SFTPNotificationCoordinator {
    private let service: any NotificationSending
    private let preferences: () -> NotificationPreferences
    private let isFocused: () -> Bool
    private let content: (Int, Int) -> (title: String, body: String)
    private var active = Set<UUID>()
    private var finished = Set<UUID>()
    private var results: [UUID: Bool] = [:]
    private var stopped = false
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        service: any NotificationSending,
        initialTransfers: [SFTPTransfer] = [],
        preferences: @escaping () -> NotificationPreferences,
        isFocused: @escaping () -> Bool,
        content: @escaping (Int, Int) -> (title: String, body: String)
    ) {
        self.service = service
        self.preferences = preferences
        self.isFocused = isFocused
        self.content = content
        active = Set(initialTransfers.filter { $0.state.isActive }.map(\.id))
        finished = Set(initialTransfers.filter { $0.state.isFinished }.map(\.id))
    }

    public func receive(_ transfer: SFTPTransfer) {
        guard !stopped else { return }
        switch transfer.state {
        case .queued, .running:
            active.insert(transfer.id)
            finished.remove(transfer.id)
            results[transfer.id] = nil
        case .paused, .cancelled:
            active.remove(transfer.id)
            results[transfer.id] = nil
        case .completed, .failed:
            active.remove(transfer.id)
            if finished.insert(transfer.id).inserted { results[transfer.id] = transfer.state == .completed }
        }
        guard active.isEmpty, !results.isEmpty else { return }
        let succeeded = results.values.filter { $0 }.count
        let failed = results.count - succeeded
        results.removeAll()
        guard preferences().allowsSFTP(isFocused: isFocused()) else { return }
        let text = content(succeeded, failed)
        let notification = AppNotification(target: .transfers, title: text.title, body: text.body)
        tasks[notification.id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[notification.id] = nil }
            await service.send(notification) { [weak self] in
                guard let self else { return false }
                return !stopped && preferences().allowsSFTP(isFocused: isFocused())
            }
        }
    }

    /// Dropping history does not discard outcomes waiting for the rest of their batch.
    public func forgetFinishedTransfers(_ ids: Set<UUID>) { finished.subtract(ids) }

    public func stop() {
        stopped = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        active.removeAll()
        finished.removeAll()
        results.removeAll()
    }
}
