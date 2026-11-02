// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication

@MainActor
final class ConnectionRecoveryActivityObserver {
    enum Event {
        case systemWillSleep
        case systemDidWake
        case sessionDidResignActive
        case sessionDidBecomeActive
        case applicationDidBecomeActive
    }

    private let availability: ConnectionRecoveryAvailability
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

    init(availability: ConnectionRecoveryAvailability) {
        self.availability = availability
    }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let notifications: [(NotificationCenter, Notification.Name, Event)] = [
            (workspace, NSWorkspace.willSleepNotification, .systemWillSleep),
            (workspace, NSWorkspace.didWakeNotification, .systemDidWake),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
            (.default, NSApplication.didBecomeActiveNotification, .applicationDidBecomeActive),
        ]
        for (center, name, event) in notifications {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(event) }
            }
            tokens.append((center, token))
        }
    }

    func receive(_ event: Event) {
        switch event {
        case .systemWillSleep: availability.setBlocked(true, by: .systemSleep)
        case .systemDidWake: availability.setBlocked(false, by: .systemSleep)
        case .sessionDidResignActive: availability.setBlocked(true, by: .inactiveSession)
        case .sessionDidBecomeActive: availability.setBlocked(false, by: .inactiveSession)
        case .applicationDidBecomeActive: break
        }
        switch event {
        case .systemDidWake, .sessionDidBecomeActive, .applicationDidBecomeActive:
            availability.requestRecheck()
        default: break
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    isolated deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
