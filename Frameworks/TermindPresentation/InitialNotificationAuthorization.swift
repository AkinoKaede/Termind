// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication

/// Let each platform present its native notification authorization UI once a scene is active.
public struct InitialNotificationAuthorization: ViewModifier {
    private let model: NotificationSettingsModel
    private let service: any NotificationSending
    @Environment(\.scenePhase) private var scenePhase

    public init(model: NotificationSettingsModel, service: any NotificationSending) {
        self.model = model
        self.service = service
    }

    public func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.requestInitialAuthorization(using: service)
        }
    }
}
