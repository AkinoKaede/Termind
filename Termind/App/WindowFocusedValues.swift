import SwiftUI

/// Routes menu commands to the frontmost Termind window without making the
/// window state itself depend on SwiftUI.
private struct WindowFocusedValueKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var window: WindowModel? {
        get { self[WindowFocusedValueKey.self] }
        set { self[WindowFocusedValueKey.self] = newValue }
    }
}
