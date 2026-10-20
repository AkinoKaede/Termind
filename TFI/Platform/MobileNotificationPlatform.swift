// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import UIKit

@MainActor
enum MobileNotificationPlatform {
    static func activate(sessionID: String, failed: @escaping @MainActor () -> Void) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let session = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == sessionID })
        else {
            failed()
            return
        }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil) { _ in
            Task { @MainActor in failed() }
        }
    }
}
