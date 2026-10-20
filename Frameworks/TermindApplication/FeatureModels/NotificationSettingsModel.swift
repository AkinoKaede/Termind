// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// Settings edits persist first, then update every notification source.
@Observable
public final class NotificationSettingsModel {
    public private(set) var preferences = NotificationPreferences()
    public private(set) var storageError: String?
    private let persistence: (any NotificationPreferencesPersisting)?
    private var didRequestInitialAuthorization = false

    public init(persistence: (any NotificationPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadNotificationPreferences() } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func set<Value>(_ value: Value, for keyPath: WritableKeyPath<NotificationPreferences, Value>) -> Bool {
        var next = preferences
        next[keyPath: keyPath] = value
        guard next.isValid else { return false }
        guard next != preferences else { return true }
        do {
            try persistence?.saveNotificationPreferences(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: NotificationPreferences) {
        preferences = value
        storageError = nil
    }

    /// Shared by all scenes so becoming active cannot repeat the initial system prompt.
    public func requestInitialAuthorization(using service: any NotificationSending) async {
        guard !Task.isCancelled, !didRequestInitialAuthorization,
            storageError == nil, preferences.usesSystemNotifications
        else { return }
        didRequestInitialAuthorization = true
        _ = await service.authorization(request: true)
    }
}
