// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication

/// System and login-session notifications must remain active after the last window closes.
/// A wake alone is insufficient: the Data Protection Keychain remains unavailable
/// until the user's login session becomes active again.
@MainActor
final class MetricsActivityObserver {
    nonisolated enum Event: Sendable {
        case systemWillSleep
        case systemDidWake
        case sessionDidResignActive
        case sessionDidBecomeActive
    }

    private enum Blocker: Hashable {
        case systemSleep
        case inactiveSession
    }

    private var tokens: [any NSObjectProtocol] = []
    private var blockers: Set<Blocker> = []
    private weak var model: ServerMetricsModel?

    func start(_ model: ServerMetricsModel) {
        guard tokens.isEmpty else { return }
        self.model = model
        let notifications: [(Notification.Name, Event)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        ]
        for (name, event) in notifications {
            tokens.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in
                        self?.receive(event)
                    }
                })
        }
    }

    func receive(_ event: Event) {
        let wasSuspended = !blockers.isEmpty
        switch event {
        case .systemWillSleep:
            blockers.insert(.systemSleep)
        case .systemDidWake:
            blockers.remove(.systemSleep)
        case .sessionDidResignActive:
            blockers.insert(.inactiveSession)
        case .sessionDidBecomeActive:
            blockers.remove(.inactiveSession)
        }
        let isSuspended = !blockers.isEmpty
        guard wasSuspended != isSuspended else { return }
        if isSuspended {
            model?.suspend()
        } else {
            model?.resume()
        }
    }

    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []
        blockers = []
        model = nil
    }
}
