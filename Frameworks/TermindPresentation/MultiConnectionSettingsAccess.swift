// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

/// Editing-only projections. Reading a free value never overwrites the saved choice.
public struct MultiConnectionSettingsAccess {
    public var isAllowed: Bool
    private let requestAccess: () -> Void

    public init(isAllowed: Bool, requestAccess: @escaping () -> Void) {
        self.isAllowed = isAllowed
        self.requestAccess = requestAccess
    }

    private var policy: MultiConnectionPolicy { .init(allowsMultipleConnections: isAllowed) }

    public func strategy(for model: SFTPSettingsModel) -> Binding<SFTPConcurrencyStrategy> {
        Binding(
            get: { policy.sftpStrategy(model.preferences.strategy) },
            set: { value in
                guard isAllowed else {
                    if value != policy.sftpStrategy(value) { requestAccess() }
                    return
                }
                model.setStrategy(value)
            })
    }

    public func forwardingConnections(_ saved: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { policy.forwardingConnections(saved.wrappedValue) },
            set: { value in
                guard isAllowed else {
                    if value > policy.forwardingConnections(value) { requestAccess() }
                    return
                }
                saved.wrappedValue = policy.forwardingConnections(value)
            })
    }
}
