import SwiftUI

nonisolated enum MobileLayout: Sendable {
    case compact
    case regular

    init(sizeClass: UserInterfaceSizeClass?) {
        self = sizeClass == .regular ? .regular : .compact
    }
}

extension EnvironmentValues {
    @Entry var mobileLayout: MobileLayout? = nil
}
