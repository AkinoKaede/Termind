import SwiftUI

struct MobileConnectionFeedbackContext {
    var isForeground: @MainActor () -> Bool = { false }
    var succeeded: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    @Entry var mobileConnectionFeedback = MobileConnectionFeedbackContext()
}
