// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum SFTPNotificationContent {
    public static func make(succeeded: Int, failed: Int) -> (title: String, body: String) {
        (
            String(localized: AppStrings.SFTP.transfers),
            String(localized: AppStrings.Notifications.transfersCompleted(succeeded: succeeded, failed: failed))
        )
    }
}
