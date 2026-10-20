// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Observation

/// Watches only live app state. Badge counts never enter settings or persistence.
@MainActor
public final class NotificationBadgeCoordinator {
    private let service: any NotificationSending
    private let count: @MainActor () -> Int
    private var active = true

    public init(service: any NotificationSending, count: @escaping @MainActor () -> Int) {
        self.service = service
        self.count = count
        observe()
    }

    public func stop() {
        active = false
        service.setBadgeCount(0)
    }

    private func observe() {
        guard active else { return }
        let value = withObservationTracking {
            count()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        service.setBadgeCount(value)
    }
}
