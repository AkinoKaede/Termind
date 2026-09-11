import UIKit

@MainActor
final class MobileBackgroundController {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin(expiration: @escaping @MainActor () -> Void) {
        finish()
        task = UIApplication.shared.beginBackgroundTask(withName: "Finish remote session work") { [weak self] in
            Task { @MainActor in
                expiration()
                self?.finish()
            }
        }
        if task == .invalid { expiration() }
    }

    func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
