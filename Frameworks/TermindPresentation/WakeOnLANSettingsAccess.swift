import SwiftUI
import TermindDomain

public struct WakeOnLANSettingsAccess {
    private let requestAccess: () -> Bool
    private let invalidAddress: () -> Void

    public init(requestAccess: @escaping () -> Bool, invalidAddress: @escaping () -> Void) {
        self.requestAccess = requestAccess
        self.invalidAddress = invalidAddress
    }

    public func automatic(_ saved: Binding<WakeOnLANPreferences>) -> Binding<Bool> {
        Binding(
            get: { saved.wrappedValue.automaticallyWake },
            set: { enabled in
                if enabled {
                    guard requestAccess() else { return }
                    guard saved.wrappedValue.address != nil else {
                        invalidAddress()
                        return
                    }
                }
                saved.wrappedValue.automaticallyWake = enabled
            })
    }
}
