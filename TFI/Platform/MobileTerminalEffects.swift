import UIKit

@MainActor
struct MobileTerminalEffects {
    var sound: @MainActor () -> Void = {}
    var vibration: @MainActor () -> Void = {}
    var connectionSucceeded: @MainActor () -> Void = {}
    var setIdleTimerDisabled: @MainActor (Bool) -> Void = { _ in }

    static var live: Self {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return Self() }
        let bellFeedback = UIImpactFeedbackGenerator(style: .light)
        return Self(
            sound: TerminalNotificationPlatform.ringBell,
            vibration: { bellFeedback.impactOccurred() },
            connectionSucceeded: { UINotificationFeedbackGenerator().notificationOccurred(.success) },
            setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })
    }
}
