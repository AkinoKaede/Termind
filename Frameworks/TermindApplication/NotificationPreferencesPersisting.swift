// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol NotificationPreferencesPersisting: AnyObject {
    func loadNotificationPreferences() throws -> NotificationPreferences
    func saveNotificationPreferences(_ value: NotificationPreferences) throws
}
