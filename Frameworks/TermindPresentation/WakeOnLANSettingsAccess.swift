// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

public struct WakeOnLANSettingsAccess {
    private let invalidAddress: () -> Void

    public init(invalidAddress: @escaping () -> Void) {
        self.invalidAddress = invalidAddress
    }

    public func automatic(_ saved: Binding<WakeOnLANPreferences>) -> Binding<Bool> {
        Binding(
            get: { saved.wrappedValue.automaticallyWake },
            set: { enabled in
                if enabled {
                    guard saved.wrappedValue.address != nil else {
                        invalidAddress()
                        return
                    }
                }
                saved.wrappedValue.automaticallyWake = enabled
            })
    }
}
