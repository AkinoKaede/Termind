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

    public func strategy(for model: SFTPSettingsModel) -> Binding<SFTPConcurrencyStrategy> {
        Binding(
            get: { isAllowed ? model.preferences.strategy : .channelsOnly },
            set: { value in
                guard isAllowed else {
                    if value != .channelsOnly { requestAccess() }
                    return
                }
                model.setStrategy(value)
            })
    }

    public func forwardingConnections(_ saved: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { isAllowed ? saved.wrappedValue : 1 },
            set: { value in
                guard isAllowed else {
                    if value > 1 { requestAccess() }
                    return
                }
                saved.wrappedValue = Host.normalizedPortForwardingMaxConnections(value)
            })
    }
}
