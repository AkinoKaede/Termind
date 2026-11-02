// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Platform lifecycle is a hint, not proof that protected credentials are readable.
@MainActor
public final class ConnectionRecoveryAvailability {
    public enum Blocker: Hashable, Sendable {
        case systemSleep
        case inactiveSession
    }

    private var blockers: Set<Blocker> = []
    private var observers: [UUID: @MainActor () -> Void] = [:]

    public var isAvailable: Bool { blockers.isEmpty }

    public init() {}

    public func setBlocked(_ blocked: Bool, by blocker: Blocker) {
        let wasAvailable = isAvailable
        if blocked { blockers.insert(blocker) } else { blockers.remove(blocker) }
        if wasAvailable != isAvailable { notify() }
    }

    public func requestRecheck() {
        guard isAvailable else { return }
        notify()
    }

    func observe(_ action: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for action in Array(observers.values) { action() }
    }
}
